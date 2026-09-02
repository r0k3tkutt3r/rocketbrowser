import Cocoa
import WebKit

/// The in-page half of autofill: a detection script in an isolated content world that
/// reports login fields, focus and submits, and fills on request.
///
/// Three things make this safe to run on every page:
///
/// 1. **Isolated world.** The script and its message handler live in
///    `WKContentWorld.world(name:)`, so a page can neither see `window.__rocketPasswords`
///    nor post to the handler. The world also has its own copies of the DOM prototypes,
///    so a page that overrides `HTMLInputElement.prototype.value` cannot intercept a fill.
/// 2. **The page never learns what is saved.** Only field ids, rectangles, focus and
///    submitted values travel outward; the account list is drawn natively, and exactly
///    one credential ever comes back, after a click in native UI.
/// 3. **It is re-added by `ContentBlocker.apply`,** which wipes all user scripts, so a
///    settings toggle can never strip it — the same invariant PrivacyShield relies on.
enum PasswordAutofill {

    static let worldName = "RocketPasswords"
    static let handlerName = "rocketPasswords"
    static var world: WKContentWorld { WKContentWorld.world(name: worldName) }

    static func userScripts() -> [WKUserScript] {
        [WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world)]
    }

    static let script = #"""
    (function () {
        'use strict';
        if (window.__rocketPasswords) { return; }
        var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rocketPasswords;
        if (!bridge) { return; }
        function post(message) { try { bridge.postMessage(message); } catch (e) {} }

        // --- element bookkeeping: Swift only ever speaks in these ids ---------------
        var ids = new WeakMap();
        var elements = {};
        var nextId = 1;
        function idFor(el) {
            var id = ids.get(el);
            if (!id) { id = nextId++; ids.set(el, id); elements[id] = el; }
            return id;
        }
        // Only a field the user typed into (or Rocket filled) is worth offering to save;
        // a value the page pre-filled is not the user's password.
        var touched = new WeakSet();
        var filledByRocket = new WeakMap();
        var nativeValueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;

        function isVisible(el) {
            if (!el || !el.isConnected || el.disabled) { return false; }
            var rect = el.getBoundingClientRect();
            if (rect.width < 2 || rect.height < 2) { return false; }
            var style = getComputedStyle(el);
            return style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
        }
        var textTypes = { text: true, email: true, tel: true, url: true };
        function isPasswordField(el) {
            return !!el && el.tagName === 'INPUT' && !el.readOnly
                && (el.getAttribute('type') || '').toLowerCase() === 'password' && isVisible(el);
        }
        function isUsernameCandidate(el) {
            if (!el || el.tagName !== 'INPUT') { return false; }
            var type = (el.getAttribute('type') || 'text').toLowerCase();
            if (!textTypes[type]) { return false; }
            var autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase();
            // A one-time code or a card field is never a username.
            if (autocomplete.indexOf('one-time-code') >= 0 || autocomplete.indexOf('cc-') >= 0) { return false; }
            return isVisible(el);
        }
        function looksLikeUsername(el) {
            var autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase();
            if (autocomplete === 'username' || autocomplete === 'email') { return true; }
            if ((el.getAttribute('type') || '').toLowerCase() === 'email') { return true; }
            var hint = ((el.name || '') + ' ' + (el.id || '') + ' ' + (el.getAttribute('placeholder') || '')
                + ' ' + (el.getAttribute('aria-label') || '')).toLowerCase();
            return /user|email|login|account|identifier|phone|mobile/.test(hint);
        }
        function precedes(a, b) { return !!(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING); }
        function commonAncestor(a, b) {
            var node = a;
            while (node && !node.contains(b)) { node = node.parentElement; }
            return node || document.body;
        }

        // The username field for a password field: the closest preceding visible text
        // input in the same form, preferring one that announces itself as a username.
        function usernameFor(password) {
            var scope = password.form;
            if (!scope) {
                var node = password.parentElement;
                while (node && node !== document.body) {
                    if (Array.prototype.some.call(node.querySelectorAll('input'), isUsernameCandidate)) { scope = node; break; }
                    node = node.parentElement;
                }
                scope = scope || document.body;
            }
            var before = Array.prototype.filter.call(scope.querySelectorAll('input'), function (el) {
                return isUsernameCandidate(el) && precedes(el, password);
            });
            if (!before.length) { return null; }
            var announced = before.filter(looksLikeUsername);
            var pool = announced.length ? announced : before;
            return pool[pool.length - 1];
        }

        // One record per login form on the page.
        function analyze() {
            var passwords = Array.prototype.filter.call(document.querySelectorAll('input[type=password]'), isPasswordField);
            var records = [];
            var seenForms = [];
            passwords.forEach(function (password) {
                var form = password.form;
                if (form) {
                    if (seenForms.indexOf(form) >= 0) { return; }
                    seenForms.push(form);
                }
                var group = form ? passwords.filter(function (p) { return p.form === form; }) : [password];
                // Two password boxes, or an explicit new-password hint, means the user is
                // creating an account rather than signing in.
                var isSignUp = group.length >= 2 || group.some(function (p) {
                    return (p.getAttribute('autocomplete') || '').toLowerCase() === 'new-password';
                });
                records.push({ form: form, password: group[0], passwords: group,
                               username: usernameFor(group[0]), isSignUp: isSignUp });
            });
            return records;
        }
        // Where a formless login's submit button is expected to live.
        function scopeOf(record) {
            if (record.form) { return record.form; }
            var base = record.username ? commonAncestor(record.username, record.password) : record.password.parentElement;
            for (var i = 0; i < 3 && base && base.parentElement && base.parentElement !== document.body; i++) {
                base = base.parentElement;
            }
            return base || document.body;
        }
        // A username-only step (Google, Microsoft): a username-looking field on a page
        // with no visible password field at all.
        function isUsernameOnly(el) {
            if (!isUsernameCandidate(el) || !looksLikeUsername(el)) { return false; }
            return !Array.prototype.some.call(document.querySelectorAll('input[type=password]'), isPasswordField);
        }
        function classify(el) {
            if (!el || el.tagName !== 'INPUT') { return null; }
            var records = analyze();
            for (var i = 0; i < records.length; i++) {
                var record = records[i];
                if (record.passwords.indexOf(el) >= 0) { return { kind: 'password', record: record, usernameOnly: false }; }
                if (record.username === el) { return { kind: 'username', record: record, usernameOnly: false }; }
            }
            if (isUsernameOnly(el)) { return { kind: 'username', record: null, usernameOnly: true }; }
            return null;
        }

        // --- geometry -------------------------------------------------------------
        // CSS pixels relative to the top-level viewport, plus that viewport's width so
        // the native side can derive one scale factor covering page zoom. Null across
        // an origin boundary, where the offset cannot be computed and the panel falls
        // back to the toolbar button.
        function rectOf(el) {
            var rect = el.getBoundingClientRect();
            var x = rect.left, y = rect.top;
            var top = window;
            try {
                while (top !== top.parent) {
                    var frame = top.frameElement;
                    if (!frame) { return null; }
                    var frameRect = frame.getBoundingClientRect();
                    x += frameRect.left + frame.clientLeft;
                    y += frameRect.top + frame.clientTop;
                    top = top.parent;
                }
            } catch (e) { return null; }
            return { x: x, y: y, width: rect.width, height: rect.height, viewportWidth: top.innerWidth };
        }

        // --- focus ----------------------------------------------------------------
        var focused = null;
        var panel = { visible: false, hasSelection: false };
        function reportFocus(el) {
            var info = classify(el);
            if (!info) {
                if (focused) { focused = null; panel.visible = false; post({ action: 'fieldBlurred' }); }
                return;
            }
            focused = { el: el, info: info };
            post({ action: 'fieldFocused', fieldID: idFor(el), kind: info.kind,
                   isSignUp: !!(info.record && info.record.isSignUp), usernameOnly: info.usernameOnly,
                   rect: rectOf(el) });
        }
        document.addEventListener('focusin', function (e) { reportFocus(e.target); }, true);
        document.addEventListener('focusout', function (e) {
            if (focused && e.target === focused.el) {
                focused = null;
                panel.visible = false;
                post({ action: 'fieldBlurred' });
            }
        }, true);
        // Clicking a field that already has focus brings the list back, like Chrome.
        document.addEventListener('mousedown', function (e) {
            if (focused && e.target === focused.el && !panel.visible) { reportFocus(e.target); }
        }, true);
        var moveTimer = null;
        function moved() {
            if (!focused || moveTimer) { return; }
            moveTimer = setTimeout(function () {
                moveTimer = null;
                if (focused) { post({ action: 'fieldMoved', fieldID: idFor(focused.el), rect: rectOf(focused.el) }); }
            }, 80);
        }
        window.addEventListener('scroll', moved, { capture: true, passive: true });
        window.addEventListener('resize', moved, { passive: true });

        // --- keys: only while the native panel is up, and only the keys it owns -----
        document.addEventListener('keydown', function (e) {
            if (!focused || e.target !== focused.el) { return; }
            var picking = panel.visible && panel.hasSelection;
            // Return with nothing selected is the user submitting the form.
            if (e.key === 'Enter' && !picking) { handleEnter(e); }
            if (!panel.visible) { return; }
            if (e.key === 'ArrowUp' || e.key === 'ArrowDown' || e.key === 'Escape' || (e.key === 'Enter' && picking)) {
                e.preventDefault();
                e.stopImmediatePropagation();
                post({ action: 'key', key: e.key });
            } else if (['Shift', 'Meta', 'Alt', 'Control', 'CapsLock'].indexOf(e.key) < 0) {
                panel.visible = false;
                post({ action: 'fieldBlurred' });
            }
        }, true);
        document.addEventListener('input', function (e) {
            if (e.target && e.target.tagName === 'INPUT') { touched.add(e.target); }
        }, true);

        // --- filling: the world's own native setter plus events, so React and Vue
        // notice the change instead of reverting it on the next render ---------------
        function setValue(el, value) {
            if (!el) { return; }
            try { el.focus(); } catch (e) {}
            nativeValueSetter.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            touched.add(el);
        }
        function fill(fieldID, username, password) {
            var el = elements[fieldID];
            var info = classify(el);
            if (!info) { return false; }
            if (info.usernameOnly) {
                if (username != null) { setValue(el, username); }
                return true;
            }
            var record = info.record;
            if (username != null && record.username) { setValue(record.username, username); }
            if (password != null) {
                record.passwords.forEach(function (p) { setValue(p, password); filledByRocket.set(p, password); });
            }
            try { el.focus(); } catch (e) {}
            return true;
        }
        function fillActive(username, password) {
            var el = focused ? focused.el : document.activeElement;
            if (classify(el)) { return fill(idFor(el), username, password); }
            var records = analyze();
            if (!records.length) { return false; }
            return fill(idFor(records[0].password), username, password);
        }
        function setPanelState(state) {
            panel.visible = !!state.visible;
            panel.hasSelection = !!state.hasSelection;
        }

        // --- saving: what was submitted, reported once per distinct value -----------
        var lastCapture = '';
        var watched = null;
        // A single-page login never navigates, so the form disappearing is the only
        // signal that the sign-in went through.
        var observer = new MutationObserver(function () {
            if (!watched) { return; }
            if (!watched.isConnected || !isVisible(watched)) {
                watched = null;
                observer.disconnect();
                post({ action: 'formVanished' });
            }
        });
        function capture(record) {
            var password = record.password.value;
            if (!password || !touched.has(record.password)) { return; }
            var username = record.username ? record.username.value : '';
            var key = username + ' ' + password;
            if (key === lastCapture) { return; }
            lastCapture = key;
            post({ action: 'credentialsSubmitted', url: location.href,
                   username: username, password: password, isSignUp: record.isSignUp,
                   filledByRocket: filledByRocket.get(record.password) === password });
            watched = record.password;
            observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true,
                                                         attributeFilter: ['style', 'class', 'hidden'] });
        }
        function captureUsername(el) {
            if (el && el.value) { post({ action: 'usernameSubmitted', username: el.value }); }
        }
        function captureAll(predicate) {
            analyze().forEach(function (record) { if (!predicate || predicate(record)) { capture(record); } });
        }
        function captureUsernameOnly() {
            var fields = Array.prototype.filter.call(document.querySelectorAll('input'), function (el) {
                return isUsernameOnly(el) && el.value;
            });
            if (fields.length) { captureUsername(fields[fields.length - 1]); }
        }
        function handleEnter(e) {
            var info = classify(e.target);
            if (!info) { return; }
            if (info.usernameOnly) { captureUsername(e.target); } else { capture(info.record); }
        }
        document.addEventListener('submit', function (e) {
            captureAll(function (record) { return record.form === e.target; });
            captureUsernameOnly();
        }, true);
        document.addEventListener('click', function (e) {
            var button = e.target && e.target.closest
                ? e.target.closest('button, input[type=submit], input[type=button], input[type=image], [role=button]')
                : null;
            if (!button) { return; }
            captureAll(function (record) { return scopeOf(record).contains(button); });
            captureUsernameOnly();
        }, true);
        window.addEventListener('pagehide', function () { captureAll(null); });

        window.__rocketPasswords = { fill: fill, fillActive: fillActive, setPanelState: setPanelState };
    })();
    """#
}

/// One bridge for every tab, routing on `message.webView`: popups share their opener's
/// content controller, so a per-tab handler would be torn out from under the opener
/// (see `NewTabPageBridge`, which learned this the hard way). `windowWillClose` must
/// therefore NOT remove it.
final class PasswordAutofillBridge: NSObject, WKScriptMessageHandler {

    static let shared = PasswordAutofillBridge()

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == PasswordAutofill.handlerName,
              let body = message.body as? [String: Any],
              let sender = message.webView,
              let controller = AppDelegate.shared.controller(for: sender) else { return }
        controller.passwordAutofill.handle(body, frame: message.frameInfo)
    }
}

/// A submitted login, held until the next page load decides whether to offer saving it.
struct PendingCredential {
    let host: String
    let url: String?
    var username: String
    let password: SecureString
    let capturedAt: Date
    let filledByRocket: Bool
    let isSignUp: Bool

    /// A prompt that arrives long after the submit is noise, not a save offer.
    static let maximumAge: TimeInterval = 60
}

/// The native half of autofill for one tab: the account panel, the fill, and the
/// pending credential the save bubble is built from.
final class PasswordAutofillController {

    private struct FocusedField {
        let id: Int
        let frame: WKFrameInfo
        let kind: String
        let isSignUp: Bool
        let usernameOnly: Bool
        var rect: CGRect?
        /// CSS width of the top-level viewport when the rectangle was measured.
        var viewportWidth: CGFloat?
    }

    private weak var owner: BrowserWindowController?
    private let dropdown = PasswordDropdown()
    private var focused: FocusedField?
    private var pendingCredential: PendingCredential?
    /// A two-page login (Google, Microsoft) submits the username on the first screen;
    /// it is remembered briefly so the password page can be saved under a name.
    private var lastUsername: (host: String, username: String, at: Date)?
    private static let usernameCarryOver: TimeInterval = 120

    init(owner: BrowserWindowController) {
        self.owner = owner
        dropdown.onAccept = { [weak self] item in self?.accept(item) }
        dropdown.onSelectionChanged = { [weak self] in self?.syncPanelState() }
    }

    // MARK: - Messages

    func handle(_ body: [String: Any], frame: WKFrameInfo) {
        guard let action = body["action"] as? String else { return }
        switch action {
        case "fieldFocused":
            fieldFocused(body, frame: frame)
        case "fieldBlurred":
            hideDropdown()
        case "fieldMoved":
            guard let current = focused, current.id == body["fieldID"] as? Int else { return }
            let geometry = Self.geometry(from: body["rect"])
            focused?.rect = geometry?.rect
            focused?.viewportWidth = geometry?.viewportWidth
            if let anchor = screenRect(for: focused) { dropdown.move(to: anchor) } else { hideDropdown() }
        case "key":
            key(body["key"] as? String ?? "")
        case "credentialsSubmitted":
            credentialsSubmitted(body, frame: frame)
        case "usernameSubmitted":
            guard let owner, let host = SiteMatcher.host(from: owner.webView.url ?? URL(fileURLWithPath: "/")),
                  let username = body["username"] as? String, !username.isEmpty else { return }
            lastUsername = (host, username, Date())
        case "formVanished":
            offerSaveIfPending()
        default:
            break
        }
    }

    private static func geometry(from value: Any?) -> (rect: CGRect, viewportWidth: CGFloat)? {
        guard let dict = value as? [String: Any],
              let x = dict["x"] as? Double, let y = dict["y"] as? Double,
              let width = dict["width"] as? Double, let height = dict["height"] as? Double,
              let viewportWidth = dict["viewportWidth"] as? Double, viewportWidth > 0 else { return nil }
        return (CGRect(x: x, y: y, width: width, height: height), CGFloat(viewportWidth))
    }

    /// A frame belongs to this page only when its registrable domain matches. Without
    /// this, a hidden iframe could harvest the accounts of the site embedding it.
    private func frameBelongsToPage(_ frame: WKFrameInfo, pageHost: String) -> Bool {
        let frameHost = frame.securityOrigin.host
        if frame.isMainFrame || frameHost.isEmpty { return true }
        return SiteMatcher.matches(entryHost: frameHost, pageHost: pageHost)
    }

    private func fieldFocused(_ body: [String: Any], frame: WKFrameInfo) {
        guard let owner, PasswordFlows.autofillEnabled,
              let pageURL = owner.webView.url, !NewTabPage.isInternalURL(pageURL),
              let pageHost = SiteMatcher.host(from: pageURL),
              frameBelongsToPage(frame, pageHost: pageHost),
              let id = body["fieldID"] as? Int else { return }
        let geometry = Self.geometry(from: body["rect"])
        let field = FocusedField(id: id, frame: frame,
                                 kind: body["kind"] as? String ?? "username",
                                 isSignUp: body["isSignUp"] as? Bool ?? false,
                                 usernameOnly: body["usernameOnly"] as? Bool ?? false,
                                 rect: geometry?.rect,
                                 viewportWidth: geometry?.viewportWidth)
        focused = field

        let store = PasswordStore.shared
        var items: [PasswordDropdownItem] = []
        if pageURL.scheme?.lowercased() == "http" {
            items.append(.caption("Not secure: this page isn't encrypted"))
        }
        // A vault this Mac cannot open has no accounts to offer, and saying so belongs
        // in the manager window, not over a login form.
        let accounts = store.needsRestore ? [] : store.entries(for: pageHost)
        for entry in accounts {
            items.append(.account(entry, showsHost: !SiteMatcher.isExact(entryHost: entry.host, pageHost: pageHost)))
        }
        if field.isSignUp, field.kind == "password" { items.append(.strongPassword) }
        guard items.contains(where: { $0.isSelectable }) else { hideDropdown(); return }
        items.append(.manage)
        guard let window = owner.window, let anchor = screenRect(for: field) else { hideDropdown(); return }
        dropdown.show(items, below: anchor, in: window)
        syncPanelState()
    }

    private func key(_ key: String) {
        guard dropdown.isVisible else { return }
        switch key {
        case "ArrowDown": dropdown.moveSelection(by: 1)
        case "ArrowUp": dropdown.moveSelection(by: -1)
        case "Enter": dropdown.acceptSelection()
        case "Escape": hideDropdown()
        default: break
        }
    }

    /// CSS pixels to screen points. The scale is derived from the reported viewport
    /// width rather than assumed, which folds page zoom (⌘+/⌘−) into one number — the
    /// same trick `ImageTextScanner` uses for its snapshot. A field scrolled out of
    /// view yields nil, and a frame that could not report its position falls back to
    /// the toolbar key button.
    private func screenRect(for field: FocusedField?) -> NSRect? {
        guard let owner, let window = owner.window else { return nil }
        guard let field, let css = field.rect, let viewportWidth = field.viewportWidth, viewportWidth > 0 else {
            return owner.passwordsAnchorScreenRect()
        }
        let webView = owner.webView
        let scale = webView.bounds.width / viewportWidth
        let scaled = NSRect(x: css.minX * scale, y: css.minY * scale,
                            width: css.width * scale, height: css.height * scale)
        // getBoundingClientRect measures from the top of the viewport; an unflipped
        // view measures from the bottom.
        let y = webView.isFlipped ? scaled.minY : webView.bounds.height - scaled.maxY
        let viewRect = NSRect(x: scaled.minX, y: y, width: scaled.width, height: scaled.height)
        guard webView.bounds.intersects(viewRect) else { return nil }
        return window.convertToScreen(webView.convert(viewRect, to: nil))
    }

    private func syncPanelState() {
        guard let owner, let focused else { return }
        owner.webView.callAsyncJavaScript(
            "if (window.__rocketPasswords) { window.__rocketPasswords.setPanelState({visible: visible, hasSelection: hasSelection}); }",
            arguments: ["visible": dropdown.isVisible, "hasSelection": dropdown.selectedIndex != nil],
            in: focused.frame, in: PasswordAutofill.world) { _ in }
    }

    func hideDropdown() {
        guard dropdown.isVisible else { return }
        dropdown.hide()
        syncPanelState()
    }

    // MARK: - Filling

    private func accept(_ item: PasswordDropdownItem) {
        guard let owner, let focused else { return }
        hideDropdown()
        switch item {
        case .account(let entry, _):
            // A username-only step needs no secret, so it needs no authentication.
            if focused.usernameOnly {
                fill(fieldID: focused.id, username: entry.username, password: nil, in: focused.frame)
                PasswordStore.shared.markUsed(id: entry.id)
                return
            }
            let reason = "fill your password for \(SiteMatcher.displayHost(entry.host))"
            PasswordStore.shared.password(for: entry.id, reason: reason) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    PasswordFlows.present(error, in: owner.window)
                case .success(let secret):
                    secret.withString {
                        self.fill(fieldID: focused.id, username: entry.username, password: $0, in: focused.frame)
                    }
                    secret.wipe()
                    PasswordStore.shared.markUsed(id: entry.id)
                }
            }
        case .strongPassword:
            fill(fieldID: focused.id, username: nil, password: PasswordGenerator.make(), in: focused.frame)
        case .manage:
            PasswordsWindowController.shared.show()
        case .caption:
            break
        }
    }

    /// The password rides as an argument, never spliced into JavaScript source.
    private func fill(fieldID: Int, username: String?, password: String?, in frame: WKFrameInfo?) {
        owner?.webView.callAsyncJavaScript(
            "return window.__rocketPasswords ? window.__rocketPasswords.fill(fieldID, username, password) : false;",
            arguments: ["fieldID": fieldID, "username": username ?? NSNull(), "password": password ?? NSNull()],
            in: frame, in: PasswordAutofill.world) { _ in }
    }

    /// The toolbar key menu: fills whatever login form the main frame has, for the
    /// pages where field detection came up empty.
    func fillFromToolbar(entryID: UUID) {
        guard let owner, let entry = PasswordStore.shared.entry(id: entryID) else { return }
        let reason = "fill your password for \(SiteMatcher.displayHost(entry.host))"
        PasswordStore.shared.password(for: entry.id, reason: reason) { result in
            switch result {
            case .failure(let error):
                PasswordFlows.present(error, in: owner.window)
            case .success(let secret):
                secret.withString { password in
                    owner.webView.callAsyncJavaScript(
                        "return window.__rocketPasswords ? window.__rocketPasswords.fillActive(username, password) : false;",
                        arguments: ["username": entry.username, "password": password],
                        in: nil, in: PasswordAutofill.world) { _ in }
                }
                secret.wipe()
                PasswordStore.shared.markUsed(id: entry.id)
            }
        }
    }

    // MARK: - Saving

    /// Held, not acted on: the next page load (or the form vanishing) decides, because
    /// a login that failed usually re-renders the same form.
    private func credentialsSubmitted(_ body: [String: Any], frame: WKFrameInfo) {
        guard let owner, !owner.isPrivate, PasswordFlows.offersToSave,
              let pageURL = owner.webView.url, let pageHost = SiteMatcher.host(from: pageURL),
              frameBelongsToPage(frame, pageHost: pageHost),
              let password = body["password"] as? String, !password.isEmpty else { return }
        var username = body["username"] as? String ?? ""
        if username.isEmpty, let last = lastUsername,
           SiteMatcher.matches(entryHost: last.host, pageHost: pageHost),
           Date().timeIntervalSince(last.at) < Self.usernameCarryOver {
            username = last.username
        }
        pendingCredential?.password.wipe()
        pendingCredential = PendingCredential(host: pageHost, url: body["url"] as? String,
                                              username: username, password: SecureString(password),
                                              capturedAt: Date(),
                                              filledByRocket: body["filledByRocket"] as? Bool ?? false,
                                              isSignUp: body["isSignUp"] as? Bool ?? false)
    }

    func offerSaveIfPending() {
        guard let owner, let pending = pendingCredential else { return }
        pendingCredential = nil
        guard Date().timeIntervalSince(pending.capturedAt) < PendingCredential.maximumAge else {
            pending.password.wipe()
            return
        }
        let store = PasswordStore.shared
        let decision = SavePolicy.decide(host: pending.host, username: pending.username,
                                         filledByRocket: pending.filledByRocket,
                                         existing: store.needsRestore ? [] : store.entriesLoaded,
                                         neverSave: PasswordFlows.neverSaveHosts,
                                         isPrivate: owner.isPrivate)
        guard decision != .ignore else { pending.password.wipe(); return }
        owner.presentSaveBubble(decision: decision, credential: pending)
    }

    // MARK: - Lifecycle

    /// The outgoing document takes its fields with it.
    func pageChanged() {
        focused = nil
        dropdown.hide()
    }

    func pageFinished() {
        offerSaveIfPending()
    }

    func teardown() {
        pendingCredential?.password.wipe()
        pendingCredential = nil
        focused = nil
        dropdown.hide()
    }
}
