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
        // Kept apart from filledByRocket: a password Rocket GENERATED is one the vault
        // has never seen, so "Rocket filled this" must not be read as "already saved".
        var generatedByRocket = new WeakMap();
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
                    // A token list: "section-signup new-password" is valid and must count.
                    return (p.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).indexOf('new-password') >= 0;
                });
                var user = usernameFor(group[0]);
                records.push({ form: form, password: group[0], passwords: group,
                               username: user, isSignUp: isSignUp,
                               // Only a field that announces itself as a username counts as
                               // evidence that this is a sign-in form; `usernameFor` will
                               // otherwise fall back to whatever text box came last.
                               usernameAnnounced: !!(user && looksLikeUsername(user)) });
            });
            return records;
        }
        // Where a formless login's submit button is expected to live.
        function scopeOf(record) {
            if (record.form) { return record.form; }
            var base = record.username ? commonAncestor(record.username, record.password) : record.password.parentElement;
            // Stop AT body, not one past it: the old guard only refused to step *to*
            // body, so a base that was already body climbed to <html> and the submit
            // search then ranged over the entire document.
            for (var i = 0; i < 3; i++) {
                if (!base || base === document.body || base === document.documentElement) { break; }
                var parent = base.parentElement;
                if (!parent || parent === document.body || parent === document.documentElement) { break; }
                base = parent;
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
        // Filling focuses the username box and then the password box, which produces
        // real focus events. Without this the account panel springs back up over a form
        // Rocket has already completed.
        var suppressFocusUntil = 0;
        function reportFocus(el) {
            if (Date.now() < suppressFocusUntil) { return; }
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
        // Every listener below is trusted-only. A page can dispatch any DOM event it
        // likes and it reaches this world too, so an ungated `focusin` would let a page
        // raise the real account panel over a decoy of its own drawing, and an ungated
        // `submit` would let it forge a save prompt for a password it chose.
        document.addEventListener('focusin', function (e) {
            if (!e.isTrusted) { return; }
            reportFocus(e.target);
        }, true);
        document.addEventListener('focusout', function (e) {
            if (!e.isTrusted) { return; }
            if (focused && e.target === focused.el) {
                focused = null;
                panel.visible = false;
                post({ action: 'fieldBlurred' });
            }
        }, true);
        // Clicking a field that already has focus brings the list back, like Chrome.
        // Trusted only, so a page cannot use it to re-arm the panel on its own.
        document.addEventListener('mousedown', function (e) {
            if (!e.isTrusted) { return; }
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
            // Synthetic events are the whole attack: DOM events reach listeners in
            // every world, so without this a page could dispatch ArrowDown + Enter at
            // a focused password field and drive the native panel into filling itself,
            // with no user interaction at all. `isTrusted` is read through this world's
            // own Event prototype, so a page cannot forge it.
            if (!e.isTrusted) { return; }
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
            // Rocket's own fills call touched.add directly, so gating this costs nothing.
            if (!e.isTrusted) { return; }
            if (e.target && e.target.tagName === 'INPUT') { touched.add(e.target); }
        }, true);

        // --- filling: the world's own native setter plus events, so React and Vue
        // notice the change instead of reverting it on the next render ---------------
        function setValue(el, value) {
            if (!el) { return; }
            suppressFocusUntil = Date.now() + 700;
            try { el.focus(); } catch (e) {}
            nativeValueSetter.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            touched.add(el);
        }
        // --- submitting after a fill ----------------------------------------------
        // Safari signs you in outright once Touch ID succeeds; this is the same idea.
        // Never called for a generated password on a sign-up form, where the person
        // still has other boxes to fill in.
        // Word-bounded, or "go" matches Google and Logout, "enter" matches Enterprise,
        // and "back" matches Feedback.
        var submitWords = /\b(log ?in|log ?on|sign ?in|sign ?on|submit|continue|next|proceed|done|go|ok)\b/i;
        // Loose on purpose: over-matching here only means Rocket declines to submit.
        // The destructive verbs are the point — a password box guarding "Delete account"
        // must never be treated as a sign-in form.
        var notSubmitWords = /forgot|reset|cancel|back|show|hide|reveal|toggle|sign ?up|register|create|new account|help|support|privacy|terms|remember|delete|remove|disable|deactivate|close|revoke|export|download|pay|purchase|buy|checkout|transfer|send|withdraw|authorat|authoris|authoriz|unlink|leave|destroy|erase|wipe|terminate|unsubscribe/i;

        /// Visible is not the same as clickable. Opacity does not inherit, so a button
        /// inside a faded-out modal computes opacity 1 on itself, and a control parked
        /// at left:-9999px has a perfectly ordinary rectangle.
        function isClickable(el) {
            if (!isVisible(el) || el.disabled || el.getAttribute('aria-disabled') === 'true') { return false; }
            var node = el;
            while (node && node !== document.documentElement) {
                var style = getComputedStyle(node);
                if (style.opacity === '0' || style.visibility === 'hidden'
                    || style.display === 'none' || style.pointerEvents === 'none') { return false; }
                node = node.parentElement;
            }
            var rect = el.getBoundingClientRect();
            if (rect.right < 1 || rect.bottom < 1) { return false; }
            // Where it is on screen, confirm it is what a click would actually land on.
            if (rect.top < window.innerHeight && rect.left < window.innerWidth) {
                var hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
                if (!hit || (hit !== el && !el.contains(hit))) { return false; }
            }
            return true;
        }

        /// The control that signs you in. Every candidate must clear the allow-list —
        /// not merely miss the deny-list — because the deny-list can only ever name
        /// dangers someone thought of, and the cost of guessing wrong is pressing a
        /// button the user never asked for.
        function findSubmitButton(scope, record) {
            var candidates = scope.querySelectorAll(
                'button, input[type=submit], input[type=image], input[type=button], [role=button]');
            var strong = null, weak = null;
            for (var i = 0; i < candidates.length; i++) {
                var el = candidates[i];
                // It has to come after the password box. This is what stops the
                // "Continue with Google" row above a login form from being chosen.
                if (!precedes(record.password, el)) { continue; }
                if (record.form && el.form !== record.form && !record.form.contains(el)) { continue; }
                if (!isClickable(el)) { continue; }
                var label = ((el.textContent || '') + ' ' + (el.getAttribute('aria-label') || '')
                    + ' ' + (el.value || '') + ' ' + (el.getAttribute('title') || '')).trim();
                if (notSubmitWords.test(label) || !submitWords.test(label)) { continue; }
                var type = (el.getAttribute('type') || '').toLowerCase();
                if (type === 'submit' || type === 'image' || (el.tagName === 'BUTTON' && !type)) {
                    if (!strong) { strong = el; }
                } else if (!weak) { weak = el; }
            }
            return strong || weak;
        }

        // What a person does: Return in the password box. Frameworks listen for this,
        // and legacy handlers still read keyCode, which the constructor cannot set.
        function pressEnter(el) {
            if (!el) { return false; }
            try { el.focus(); } catch (e) {}
            ['keydown', 'keypress', 'keyup'].forEach(function (type) {
                var event = new KeyboardEvent(type, { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true });
                try {
                    Object.defineProperty(event, 'keyCode', { get: function () { return 13; } });
                    Object.defineProperty(event, 'which', { get: function () { return 13; } });
                } catch (e) {}
                el.dispatchEvent(event);
            });
            return true;
        }

        function submitLogin(record, field) {
            var scope = scopeOf(record);
            var button = findSubmitButton(scope, record);
            // Clicking the real control is the most compatible route: it runs the
            // page's own click handlers and sends the button's name/value with the form.
            if (button) { button.click(); return true; }
            if (record.form) {
                if (typeof record.form.requestSubmit === 'function') {
                    try { record.form.requestSubmit(); return true; } catch (e) {}
                }
                try { record.form.submit(); return true; } catch (e) {}
            }
            return pressEnter(field || record.password);
        }

        function fill(fieldID, username, password, submit, generated) {
            var el = elements[fieldID];
            var info = classify(el);
            if (!info) { return false; }
            if (info.usernameOnly) {
                if (username != null) { setValue(el, username); }
                // The username-only step of a two-page sign-in: submitting is what
                // moves it on to the password screen.
                if (submit) {
                    setTimeout(function () {
                        var again = classify(el);
                        if (again && again.usernameOnly) { submitLogin({ form: el.form, password: el, username: el }, el); }
                    }, 150);
                }
                return true;
            }
            var record = info.record;
            if (username != null && record.username) { setValue(record.username, username); }
            if (password != null) {
                record.passwords.forEach(function (p) {
                    setValue(p, password);
                    filledByRocket.set(p, password);
                    if (generated) { generatedByRocket.set(p, password); }
                });
            }
            try { el.focus(); } catch (e) {}
            // Submitting needs positive evidence that this IS a sign-in form, not just
            // the absence of evidence that it is a sign-up. A lone password box guarding
            // "Enter your password to delete your account" has no username field, and
            // pressing its button is not something to guess at.
            if (submit && !record.isSignUp && record.usernameAnnounced) {
                var expected = password;
                // A beat first, so a framework has processed the input events and its
                // sign-in button is no longer disabled by its own validation.
                setTimeout(function () {
                    // The page owns those 150 ms: it can re-render the form, clear the
                    // box, or navigate. Submitting a stale or emptied form burns a login
                    // attempt, and enough of those lock an account.
                    var again = classify(el);
                    if (!again || again.usernameOnly || !again.record) { return; }
                    var current = again.record;
                    if (current.password !== record.password || current.isSignUp) { return; }
                    if (expected != null && current.password.value !== expected) { return; }
                    submitLogin(current, el);
                }, 150);
            }
            return true;
        }
        function fillActive(username, password, submit) {
            var el = focused ? focused.el : document.activeElement;
            if (classify(el)) { return fill(idFor(el), username, password, submit); }
            var records = analyze();
            if (!records.length) { return false; }
            return fill(idFor(records[0].password), username, password, submit);
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
                   filledByRocket: filledByRocket.get(record.password) === password,
                   generated: generatedByRocket.get(record.password) === password });
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
            if (!e.isTrusted) { return; }
            captureAll(function (record) { return record.form === e.target; });
            captureUsernameOnly();
        }, true);
        document.addEventListener('click', function (e) {
            if (!e.isTrusted) { return; }
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
    /// Rocket made this password up. Nothing else in the world has a copy of it.
    let generated: Bool

    /// A prompt that arrives long after the submit is noise, not a save offer — except
    /// for a generated password, where the offer is the only copy that will ever exist
    /// and filling in the rest of a sign-up form easily takes longer than a minute.
    var maximumAge: TimeInterval { generated ? 1800 : 60 }
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
            guard let pageURL = owner?.webView.url, let host = SiteMatcher.host(from: pageURL),
                  frameBelongsToPage(frame, pageHost: host),
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

    /// Filling is refused over plain http, where the credential would cross the
    /// network readable by anyone on the path. Loopback is the exception: there is no
    /// network hop, and refusing there would break local development for no gain.
    static func allowsFilling(on url: URL, host: String) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "https" { return true }
        if scheme == "http" { return SiteMatcher.isLoopback(host) }
        return false
    }

    /// A frame belongs to this page only when its registrable domain matches. Without
    /// this, a third-party iframe could be offered — and filled with — the credentials
    /// of the site embedding it.
    ///
    /// Fails closed on an empty host, which is what a sandboxed iframe's opaque origin
    /// reports. Treating "no host" as "trusted" was the dangerous reading: a sandboxed
    /// advertisement on a bank page would have been offered the bank's accounts, and a
    /// fake login form inside it could have collected the fill. A same-origin
    /// `about:blank` frame inherits its parent's host and so is unaffected.
    private func frameBelongsToPage(_ frame: WKFrameInfo, pageHost: String) -> Bool {
        if frame.isMainFrame { return true }
        let frameHost = frame.securityOrigin.host
        guard !frameHost.isEmpty else { return false }
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
        // A password handed to an unencrypted page goes out over the wire in clear
        // text, to whoever is listening. A warning row was not enough: it left the
        // decision with someone who has no way to judge it. Loopback is exempt because
        // there is no network to intercept.
        guard Self.allowsFilling(on: pageURL, host: pageHost) else {
            if let window = owner.window, let anchor = screenRect(for: field) {
                dropdown.show([.caption("Rocket won't fill a password on an unencrypted page")],
                              below: anchor, in: window)
            } else {
                hideDropdown()
            }
            return
        }
        // A vault this Mac cannot open has no accounts to offer, and saying so belongs
        // in the manager window, not over a login form.
        let accounts = store.needsRestore ? [] : store.entries(for: pageHost)
        for entry in accounts {
            items.append(.account(entry, showsHost: !SiteMatcher.isExact(entryHost: entry.host, pageHost: pageHost)))
        }
        // The row promises "Rocket will offer to save it", and a generated password is
        // gone for good if that promise is not kept: incognito never saves, and neither
        // does Rocket with "Offer to Save Passwords" switched off.
        if field.isSignUp, field.kind == "password", !owner.isPrivate, PasswordFlows.offersToSave {
            items.append(.strongPassword)
        }
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
        let webView = owner.webView
        // Every one of these has to hold for the measurement to mean anything. When one
        // does not, the toolbar key button is a known-good anchor — far better than
        // trusting a number and parking the panel in a corner of the screen.
        guard let field, let css = field.rect, let viewportWidth = field.viewportWidth,
              viewportWidth > 0, css.width > 0, css.height > 0,
              webView.bounds.width > 1, webView.bounds.height > 1 else {
            return owner.passwordsAnchorScreenRect()
        }
        // The page reports CSS pixels; this turns them into view points. A ratio far
        // from 1 means the page and the view disagree about the viewport, and the
        // result would not land anywhere near the field.
        let scale = webView.bounds.width / viewportWidth
        guard scale > 0.2, scale < 5 else { return owner.passwordsAnchorScreenRect() }
        let scaled = NSRect(x: css.minX * scale, y: css.minY * scale,
                            width: css.width * scale, height: css.height * scale)
        // getBoundingClientRect measures from the top of the viewport; an unflipped
        // view measures from the bottom.
        let y = webView.isFlipped ? scaled.minY : webView.bounds.height - scaled.maxY
        let viewRect = NSRect(x: scaled.minX, y: y, width: scaled.width, height: scaled.height)
        // Scrolled out of sight: no anchor at all rather than one clamped to an edge.
        guard webView.bounds.intersects(viewRect) else { return nil }
        let screenRect = window.convertToScreen(webView.convert(viewRect, to: nil))
        // A rect on no screen at all means something upstream is wrong; fall back
        // rather than hand the panel a position it cannot be seen at.
        guard NSScreen.screens.contains(where: { $0.frame.intersects(screenRect) }) else {
            return owner.passwordsAnchorScreenRect()
        }
        return screenRect
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
                fill(fieldID: focused.id, username: entry.username, password: nil,
                     submit: PasswordFlows.submitsAfterFill, in: focused.frame)
                markUsedIfRecorded(entry.id)
                return
            }
            let reason = "fill your password for \(SiteMatcher.displayHost(entry.host))"
            PasswordStore.shared.password(for: entry.id, reason: reason) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    PasswordFlows.present(error, in: owner.window)
                case .success(let secret):
                    defer { secret.wipe() }
                    // Authentication takes seconds, and the page is free to navigate
                    // during them. Without re-checking, a page could offer a login
                    // form, wait for the Touch ID sheet, and swap itself for another
                    // document that receives the password instead.
                    guard self.focused?.id == focused.id,
                          let nowURL = owner.webView.url,
                          let nowHost = SiteMatcher.host(from: nowURL),
                          SiteMatcher.matches(entryHost: entry.host, pageHost: nowHost) else { return }
                    secret.withString {
                        self.fill(fieldID: focused.id, username: entry.username, password: $0,
                                  submit: PasswordFlows.submitsAfterFill, in: focused.frame)
                    }
                    self.markUsedIfRecorded(entry.id)
                }
            }
        case .strongPassword:
            let generated = PasswordGenerator.make()
            // Never submitted: a sign-up form still needs the rest of its boxes.
            fill(fieldID: focused.id, username: nil, password: generated,
                 submit: false, generated: true, in: focused.frame)
            hold(generated: generated)
        case .manage:
            PasswordsWindowController.shared.show()
        case .caption:
            break
        }
    }

    /// "Last used" is a persistent trace of what you opened and when. An incognito tab
    /// may fill from the vault, but it must not leave that behind.
    private func markUsedIfRecorded(_ id: UUID) {
        guard owner?.isPrivate == false else { return }
        PasswordStore.shared.markUsed(id: id)
    }

    /// The password rides as an argument, never spliced into JavaScript source.
    private func fill(fieldID: Int, username: String?, password: String?,
                      submit: Bool, generated: Bool = false, in frame: WKFrameInfo?) {
        owner?.webView.callAsyncJavaScript(
            "return window.__rocketPasswords ? window.__rocketPasswords.fill(fieldID, username, password, submit, generated) : false;",
            arguments: ["fieldID": fieldID, "username": username ?? NSNull(),
                        "password": password ?? NSNull(), "submit": submit, "generated": generated],
            in: frame, in: PasswordAutofill.world) { _ in }
    }

    /// A generated password is held the instant it is made, not when the page submits.
    /// Everything that reaches `credentialsSubmitted` depends on the page: a submit
    /// button outside the form's scope, a router that never fires `submit`, a form that
    /// clears its fields — any of them and the capture never happens. For a password
    /// the user typed that costs a save offer; for one Rocket invented, and that the
    /// site is about to start demanding, it destroys the only copy. A real submit
    /// replaces this with the same password and the username that went with it.
    private func hold(generated password: String) {
        guard let owner, !owner.isPrivate,
              let pageURL = owner.webView.url, let host = SiteMatcher.host(from: pageURL) else { return }
        pendingCredential?.password.wipe()
        pendingCredential = PendingCredential(host: host, url: pageURL.absoluteString, username: "",
                                              password: SecureString(password), capturedAt: Date(),
                                              filledByRocket: true, isSignUp: true, generated: true)
    }

    /// The toolbar key menu: fills whatever login form the main frame has, for the
    /// pages where field detection came up empty.
    func fillFromToolbar(entryID: UUID) {
        guard let owner, let entry = PasswordStore.shared.entry(id: entryID) else { return }
        let reason = "fill your password for \(SiteMatcher.displayHost(entry.host))"
        PasswordStore.shared.password(for: entry.id, reason: reason) { [weak self] result in
            switch result {
            case .failure(let error):
                PasswordFlows.present(error, in: owner.window)
            case .success(let secret):
                defer { secret.wipe() }
                // The page can navigate while the authentication sheet is up; the
                // credential must not follow it to a different site.
                guard let nowURL = owner.webView.url, let nowHost = SiteMatcher.host(from: nowURL),
                      SiteMatcher.matches(entryHost: entry.host, pageHost: nowHost) else { return }
                secret.withString { password in
                    // Never submits: this is the fallback for pages where detection
                    // found nothing, so it fills the first login form on the page —
                    // one the user has not pointed at and cannot see Rocket choosing.
                    owner.webView.callAsyncJavaScript(
                        "return window.__rocketPasswords ? window.__rocketPasswords.fillActive(username, password, submit) : false;",
                        arguments: ["username": entry.username, "password": password,
                                    "submit": false],
                        in: nil, in: PasswordAutofill.world) { _ in }
                }
                self?.markUsedIfRecorded(entry.id)
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
        // The page supplies this string and the manager later shows it as the site and
        // opens it, so a mismatched host would let a page label its entry "apple.com".
        // Anything that does not resolve back to this page's host is discarded.
        var submittedURL = body["url"] as? String
        if let candidate = submittedURL,
           URL(string: candidate).flatMap({ SiteMatcher.host(from: $0) }) != pageHost {
            submittedURL = nil
        }
        pendingCredential?.password.wipe()
        pendingCredential = PendingCredential(host: pageHost, url: submittedURL,
                                              username: username, password: SecureString(password),
                                              capturedAt: Date(),
                                              filledByRocket: body["filledByRocket"] as? Bool ?? false,
                                              isSignUp: body["isSignUp"] as? Bool ?? false,
                                              generated: body["generated"] as? Bool ?? false)
    }

    func offerSaveIfPending() {
        guard let owner, let pending = pendingCredential else { return }
        pendingCredential = nil
        guard Date().timeIntervalSince(pending.capturedAt) < pending.maximumAge else {
            pending.password.wipe()
            return
        }
        let store = PasswordStore.shared
        let decision = SavePolicy.decide(host: pending.host, username: pending.username,
                                         filledByRocket: pending.filledByRocket,
                                         generated: pending.generated,
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
