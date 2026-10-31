import Cocoa
import WebKit

/// Passkeys in the page: `navigator.credentials.create/get` for `publicKey` are
/// answered by Rocket's own authenticator (`WebAuthn`), with the keys in the vault.
///
/// Unlike autofill this script has to run in the page's own world, because that is
/// where the page calls `navigator.credentials`. So the handler is reachable by any
/// page, and nothing the page sends is trusted: the origin comes from the frame's
/// `WKSecurityOrigin`, `clientDataJSON` is built natively, and nothing is created or
/// signed without a click in native UI followed by the vault's own authentication.
/// A page posting to the handler directly gets exactly what calling the real API gets.
///
/// WKWebView's own WebAuthn needs a restricted browser entitlement an ad-hoc build
/// cannot carry, which is why this replaces it instead of passing through. Hardware
/// security keys and phone (hybrid/QR) sign-in are therefore not offered.
enum Passkeys {

    static let handlerName = "rocketPasskeys"

    static func userScripts() -> [WKUserScript] {
        [WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)]
    }

    static let script = #"""
    (function () {
        'use strict';
        var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rocketPasskeys;
        var container = navigator.credentials;
        if (!handler || !container || container.__rocketPasskeys) { return; }
        Object.defineProperty(container, '__rocketPasskeys', { value: true });
        var post = handler.postMessage.bind(handler);
        var nativeCreate = container.create ? container.create.bind(container) : null;
        var nativeGet = container.get ? container.get.bind(container) : null;
        var hidden = new WeakMap();
        var pending = {};
        var counter = 0;

        function bytes(source) {
            if (source instanceof ArrayBuffer) { return new Uint8Array(source); }
            if (ArrayBuffer.isView(source)) { return new Uint8Array(source.buffer, source.byteOffset, source.byteLength); }
            throw new TypeError('Expected a BufferSource');
        }
        function b64u(source) {
            var view = bytes(source), text = '';
            for (var i = 0; i < view.length; i++) { text += String.fromCharCode(view[i]); }
            return btoa(text).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
        }
        function unb64u(text) {
            var raw = atob(text.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((text.length + 3) % 4));
            var out = new Uint8Array(raw.length);
            for (var i = 0; i < raw.length; i++) { out[i] = raw.charCodeAt(i); }
            return out.buffer;
        }
        function descriptors(list) {
            return (list || []).map(function (d) { return { type: d.type || 'public-key', id: b64u(d.id) }; });
        }

        function illegal(name, parent) {
            var C = function () { throw new TypeError('Illegal constructor'); };
            Object.defineProperty(C, 'name', { value: name });
            if (parent) {
                C.prototype = Object.create(parent.prototype, { constructor: { value: C, writable: true, configurable: true } });
            }
            Object.defineProperty(C.prototype, Symbol.toStringTag, { value: name });
            return C;
        }
        function field(name) { return function () { return hidden.get(this).raw[name]; }; }
        var AuthenticatorResponse = illegal('AuthenticatorResponse');
        var AttestationResponse = illegal('AuthenticatorAttestationResponse', AuthenticatorResponse);
        var AssertionResponse = illegal('AuthenticatorAssertionResponse', AuthenticatorResponse);
        var PublicKeyCredential = illegal('PublicKeyCredential', window.Credential);
        Object.defineProperty(AuthenticatorResponse.prototype, 'clientDataJSON', { get: field('clientDataJSON') });
        Object.defineProperty(AttestationResponse.prototype, 'attestationObject', { get: field('attestationObject') });
        AttestationResponse.prototype.getAuthenticatorData = function () { return hidden.get(this).raw.authenticatorData.slice(0); };
        AttestationResponse.prototype.getPublicKey = function () { return hidden.get(this).raw.publicKey.slice(0); };
        AttestationResponse.prototype.getPublicKeyAlgorithm = function () { return hidden.get(this).json.publicKeyAlgorithm; };
        AttestationResponse.prototype.getTransports = function () { return hidden.get(this).json.transports.slice(); };
        ['authenticatorData', 'signature', 'userHandle'].forEach(function (name) {
            Object.defineProperty(AssertionResponse.prototype, name, { get: field(name) });
        });
        ['id', 'type', 'authenticatorAttachment'].forEach(function (name) {
            Object.defineProperty(PublicKeyCredential.prototype, name, { get: function () { return hidden.get(this).json[name]; } });
        });
        Object.defineProperty(PublicKeyCredential.prototype, 'rawId', { get: field('rawId') });
        Object.defineProperty(PublicKeyCredential.prototype, 'response', { get: function () { return hidden.get(this).response; } });
        PublicKeyCredential.prototype.getClientExtensionResults = function () {
            return JSON.parse(JSON.stringify(hidden.get(this).json.clientExtensionResults || {}));
        };
        PublicKeyCredential.prototype.toJSON = function () { return JSON.parse(JSON.stringify(hidden.get(this).json)); };
        PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function () { return Promise.resolve(true); };
        PublicKeyCredential.isConditionalMediationAvailable = function () { return Promise.resolve(true); };
        PublicKeyCredential.getClientCapabilities = function () {
            return Promise.resolve({ conditionalGet: true, conditionalCreate: false, hybridTransport: false,
                passkeyPlatformAuthenticator: true, userVerifyingPlatformAuthenticator: true, relatedOrigins: false,
                signalAllAcceptedCredentials: false, signalCurrentUserDetails: false, signalUnknownCredential: false });
        };
        function parseDescriptors(list) {
            return (list || []).map(function (d) { var o = Object.assign({}, d); o.id = unb64u(d.id); return o; });
        }
        PublicKeyCredential.parseCreationOptionsFromJSON = function (json) {
            var o = Object.assign({}, json);
            o.challenge = unb64u(json.challenge);
            o.user = Object.assign({}, json.user, { id: unb64u(json.user.id) });
            o.excludeCredentials = parseDescriptors(json.excludeCredentials);
            return o;
        };
        PublicKeyCredential.parseRequestOptionsFromJSON = function (json) {
            var o = Object.assign({}, json);
            o.challenge = unb64u(json.challenge);
            o.allowCredentials = parseDescriptors(json.allowCredentials);
            return o;
        };
        [['PublicKeyCredential', PublicKeyCredential], ['AuthenticatorResponse', AuthenticatorResponse],
         ['AuthenticatorAttestationResponse', AttestationResponse], ['AuthenticatorAssertionResponse', AssertionResponse]]
            .forEach(function (pair) {
                Object.defineProperty(window, pair[0], { value: pair[1], writable: true, configurable: true });
            });

        function credential(json) {
            var r = json.response, raw = {};
            Object.keys(r).forEach(function (key) {
                if (typeof r[key] === 'string' && key !== 'publicKeyAlgorithm') { raw[key] = unb64u(r[key]); }
            });
            var response = Object.create((r.attestationObject ? AttestationResponse : AssertionResponse).prototype);
            hidden.set(response, { raw: raw, json: r });
            var made = Object.create(PublicKeyCredential.prototype);
            hidden.set(made, { raw: { rawId: unb64u(json.rawId) }, json: json, response: response });
            return made;
        }

        function run(action, publicKey, signal, conditional) {
            if (signal && signal.aborted) {
                return Promise.reject(signal.reason !== undefined ? signal.reason : new DOMException('Aborted', 'AbortError'));
            }
            var requestID = String(++counter);
            return new Promise(function (resolve, reject) {
                function settle() { delete pending[requestID]; if (signal) { signal.removeEventListener('abort', abort); } }
                function abort() {
                    if (!pending[requestID]) { return; }
                    settle();
                    post({ action: 'cancel', requestID: requestID });
                    reject(signal && signal.reason !== undefined ? signal.reason : new DOMException('Aborted', 'AbortError'));
                }
                pending[requestID] = abort;
                if (signal) { signal.addEventListener('abort', abort); }
                post({ action: action, requestID: requestID, publicKey: publicKey, conditional: conditional })
                    .then(function (reply) {
                        if (!pending[requestID]) { return; }
                        settle();
                        if (reply && reply.error) { reject(new DOMException(reply.message || '', reply.error)); }
                        else { resolve(credential(reply)); }
                    }, function (error) {
                        if (!pending[requestID]) { return; }
                        settle();
                        reject(new DOMException(String(error && error.message || error), 'NotAllowedError'));
                    });
            });
        }

        Object.defineProperty(container, 'create', { configurable: true, writable: true, value: function (options) {
            if (!options || !options.publicKey) {
                return nativeCreate ? nativeCreate(options) : Promise.reject(new DOMException('Not supported', 'NotSupportedError'));
            }
            try {
                var pk = options.publicKey;
                return run('create', {
                    rp: { id: pk.rp && pk.rp.id, name: pk.rp && pk.rp.name },
                    user: { id: b64u(pk.user.id), name: pk.user.name, displayName: pk.user.displayName },
                    challenge: b64u(pk.challenge),
                    pubKeyCredParams: (pk.pubKeyCredParams || []).map(function (p) { return { type: p.type, alg: p.alg }; }),
                    excludeCredentials: descriptors(pk.excludeCredentials),
                    extensions: { credProps: !!(pk.extensions && pk.extensions.credProps) }
                }, options.signal, false);
            } catch (e) { return Promise.reject(e); }
        } });

        Object.defineProperty(container, 'get', { configurable: true, writable: true, value: function (options) {
            if (!options || !options.publicKey) {
                return nativeGet ? nativeGet(options) : Promise.resolve(null);
            }
            try {
                var pk = options.publicKey;
                return run('get', {
                    rpId: pk.rpId, challenge: b64u(pk.challenge), allowCredentials: descriptors(pk.allowCredentials)
                }, options.signal, options.mediation === 'conditional');
            } catch (e) { return Promise.reject(e); }
        } });

        // A conditional request outlives nothing: leaving the page withdraws it, so the
        // account list never offers a passkey to a document that is gone.
        window.addEventListener('pagehide', function () {
            Object.keys(pending).forEach(function (id) { post({ action: 'cancel', requestID: id }); });
        });
    })();
    """#
}

/// One handler for every tab, routing on `message.webView` — the same popup reasoning
/// as `PasswordAutofillBridge`, so `windowWillClose` must not remove it either.
final class PasskeyBridge: NSObject, WKScriptMessageHandlerWithReply {

    static let shared = PasskeyBridge()

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.name == Passkeys.handlerName,
              let body = message.body as? [String: Any],
              let sender = message.webView,
              let controller = AppDelegate.shared.controller(for: sender) else {
            replyHandler(WebAuthn.Failure.notAllowed("No browser tab.").reply, nil)
            return
        }
        controller.passkeys.handle(body, frame: message.frameInfo, reply: replyHandler)
    }
}

/// The native half for one tab: the sheets, the vault calls, and the one conditional
/// request a page may leave waiting for the account list under its username field.
final class PasskeyController {

    typealias Reply = (Any?, String?) -> Void

    struct Conditional {
        let requestID: String
        let request: WebAuthn.Request
        let origin: WebAuthn.Origin
        let crossOrigin: Bool
        let reply: Reply
    }

    private weak var owner: BrowserWindowController?
    private(set) var conditional: Conditional?
    /// The modal request on screen, so the page aborting it takes the sheet down too.
    private var modal: (requestID: String, reply: Reply, alert: NSAlert)?

    init(owner: BrowserWindowController) {
        self.owner = owner
    }

    func handle(_ body: [String: Any], frame: WKFrameInfo, reply: @escaping Reply) {
        let action = body["action"] as? String
        let requestID = body["requestID"] as? String ?? ""
        if action == "cancel" {
            cancel(requestID: requestID)
            reply(nil, nil)
            return
        }
        do {
            guard let owner, let pageURL = owner.webView.url, let pageHost = SiteMatcher.host(from: pageURL) else {
                throw WebAuthn.Failure.notAllowed("No page.")
            }
            let security = frame.securityOrigin
            guard let origin = WebAuthn.Origin(scheme: security.protocol, host: security.host, port: security.port) else {
                throw WebAuthn.Failure.security("Passkeys need a secure (https) page.")
            }
            // A third-party frame may not act for the site embedding it.
            guard frame.isMainFrame || SiteMatcher.matches(entryHost: origin.host, pageHost: pageHost) else {
                throw WebAuthn.Failure.notAllowed("Passkeys are not available in third-party frames.")
            }
            let pageOrigin = WebAuthn.Origin(scheme: pageURL.scheme ?? "", host: pageURL.host ?? "", port: pageURL.port ?? 0)
            let crossOrigin = !frame.isMainFrame && pageOrigin != origin
            let publicKey = body["publicKey"] as? [String: Any] ?? [:]
            // One ceremony at a time per tab, as in every browser: a new one replaces the old.
            dropPending(with: .notAllowed("Superseded by a newer request."))
            switch action {
            case "create":
                create(try WebAuthn.Creation(publicKey, origin: origin), requestID: requestID,
                       origin: origin, crossOrigin: crossOrigin, reply: reply)
            case "get":
                let request = try WebAuthn.Request(publicKey, origin: origin)
                if body["conditional"] as? Bool == true {
                    conditional = Conditional(requestID: requestID, request: request, origin: origin,
                                              crossOrigin: crossOrigin, reply: reply)
                } else {
                    get(request, requestID: requestID, origin: origin, crossOrigin: crossOrigin, reply: reply)
                }
            default:
                throw WebAuthn.Failure.notSupported("Unknown request.")
            }
        } catch let failure as WebAuthn.Failure {
            reply(failure.reply, nil)
        } catch {
            reply(WebAuthn.Failure.notAllowed(error.localizedDescription).reply, nil)
        }
    }

    private func cancel(requestID: String) {
        if conditional?.requestID == requestID { conditional = nil }
        if let modal, modal.requestID == requestID {
            self.modal = nil
            if let sheet = modal.alert.window.sheetParent { sheet.endSheet(modal.alert.window) }
        }
    }

    private func dropPending(with failure: WebAuthn.Failure) {
        conditional?.reply(failure.reply, nil)
        conditional = nil
        if let modal {
            self.modal = nil
            modal.reply(failure.reply, nil)
            if let sheet = modal.alert.window.sheetParent { sheet.endSheet(modal.alert.window) }
        }
    }

    /// Runs `alert` as this request's sheet. `answer` is only called if the request is
    /// still the live one when the sheet closes; a cancelled request already replied.
    private func present(_ alert: NSAlert, requestID: String, reply: @escaping Reply,
                         answer: @escaping (NSApplication.ModalResponse) -> Void) {
        modal = (requestID, reply, alert)
        PasswordFlows.run(alert, in: owner?.window) { [weak self] response in
            guard let self, self.modal?.requestID == requestID else { return }
            self.modal = nil
            answer(response)
        }
    }

    // MARK: - Registration

    private func create(_ creation: WebAuthn.Creation, requestID: String, origin: WebAuthn.Origin,
                        crossOrigin: Bool, reply: @escaping Reply) {
        guard let owner, !owner.isPrivate else {
            reply(WebAuthn.Failure.notAllowed("Rocket doesn't save passkeys from incognito windows.").reply, nil)
            return
        }
        let store = PasswordStore.shared
        if store.isSetUp, store.passkeys(forRPID: creation.rpID).contains(where: { creation.excludedIDs.contains($0.credentialID) }) {
            let alert = NSAlert()
            alert.messageText = "You Already Have a Passkey Here"
            alert.informativeText = "Rocket Passwords already holds a passkey for this account on \(creation.rpID)."
            present(alert, requestID: requestID, reply: reply) { _ in
                reply(WebAuthn.Failure.invalidState("A passkey for this account already exists.").reply, nil)
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save a Passkey for \(creation.rpID)?"
        let account = creation.userName.isEmpty ? (creation.displayName ?? "this account") : creation.userName
        alert.informativeText = """
        Rocket will create a passkey for \(account) and keep it in Rocket Passwords, \
        unlocked with Touch ID or your Mac password. It stays on this Mac (and any Mac \
        you restore your vault to with its recovery key).
        """
        alert.addButton(withTitle: "Save Passkey")
        alert.addButton(withTitle: "Cancel")
        present(alert, requestID: requestID, reply: reply) { response in
            guard response == .alertFirstButtonReturn else {
                reply(WebAuthn.Failure.notAllowed("The user cancelled.").reply, nil)
                return
            }
            PasswordFlows.ensureSetUp(from: owner.window) { ready in
                guard ready else { reply(WebAuthn.Failure.notAllowed("Rocket Passwords isn't set up.").reply, nil); return }
                let made = WebAuthn.register(creation, origin: origin, crossOrigin: crossOrigin)
                store.mutate(reason: "save a passkey for \(creation.rpID)", { index, secrets in
                    // An authenticator keeps one credential per account and site: a new one
                    // for the same user handle replaces the old.
                    let replaced = index.passkeys.filter { $0.rpID == creation.rpID && $0.userHandle == creation.userHandle }
                    index.passkeys.removeAll { old in replaced.contains { $0.id == old.id } }
                    for old in replaced { secrets.passkeyKeys[old.id.uuidString] = nil }
                    index.passkeys.append(made.entry)
                    secrets.passkeyKeys[made.entry.id.uuidString] = made.privateKey
                }, completion: { result in
                    switch result {
                    case .success: reply(made.response, nil)
                    case .failure(let error):
                        PasswordFlows.present(error, in: owner.window)
                        reply(WebAuthn.Failure.notAllowed(error.localizedDescription).reply, nil)
                    }
                })
            }
        }
    }

    // MARK: - Assertion

    private func get(_ request: WebAuthn.Request, requestID: String, origin: WebAuthn.Origin,
                     crossOrigin: Bool, reply: @escaping Reply) {
        let candidates = matching(request)
        guard !candidates.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Passkey for \(request.rpID)"
            alert.informativeText = """
            Rocket Passwords has no passkey for this site. Passkeys kept in Apple Passwords \
            or Google Password Manager can't be used by other browsers — sign in another \
            way, then create a passkey in Rocket from the site's security settings.
            """
            present(alert, requestID: requestID, reply: reply) { _ in
                reply(WebAuthn.Failure.notAllowed("No passkey available.").reply, nil)
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Sign In to \(request.rpID) with a Passkey?"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        for passkey in candidates { picker.addItem(withTitle: Self.label(passkey)) }
        if candidates.count > 1 {
            alert.accessoryView = picker
        } else {
            alert.informativeText = Self.label(candidates[0])
        }
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        present(alert, requestID: requestID, reply: reply) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                reply(WebAuthn.Failure.notAllowed("The user cancelled.").reply, nil)
                return
            }
            self?.sign(request, with: candidates[max(0, picker.indexOfSelectedItem)],
                       origin: origin, crossOrigin: crossOrigin, reply: reply)
        }
    }

    /// Passkeys the account list under a username field may offer, while the page holds
    /// a conditional request and the field is in a frame allowed to answer it.
    func conditionalOffers(forFrameHost host: String) -> [PasskeyEntry] {
        guard let conditional, WebAuthn.isValid(rpID: conditional.request.rpID, for: host) else { return [] }
        return matching(conditional.request)
    }

    /// The click in the account list is the user's consent; the vault asks for the rest.
    func acceptConditional(_ passkey: PasskeyEntry) {
        guard let pending = conditional, pending.request.admits(passkey) else { return }
        conditional = nil
        sign(pending.request, with: passkey, origin: pending.origin, crossOrigin: pending.crossOrigin,
             reply: pending.reply)
    }

    private func matching(_ request: WebAuthn.Request) -> [PasskeyEntry] {
        let store = PasswordStore.shared
        guard store.isSetUp else { return [] }
        return store.passkeys(forRPID: request.rpID).filter(request.admits)
    }

    private func sign(_ request: WebAuthn.Request, with passkey: PasskeyEntry, origin: WebAuthn.Origin,
                      crossOrigin: Bool, reply: @escaping Reply) {
        PasswordStore.shared.withSecrets(reason: "sign in to \(passkey.rpID) with a passkey", { secrets in
            guard let key = secrets.passkeyKeys[passkey.id.uuidString] else {
                throw WebAuthn.Failure.notAllowed("This passkey's key is missing.")
            }
            return try WebAuthn.assert(request, passkey: passkey, privateKey: key, origin: origin, crossOrigin: crossOrigin)
        }, completion: { [weak self] result in
            switch result {
            case .success(let response):
                reply(response, nil)
                if self?.owner?.isPrivate == false { PasswordStore.shared.markUsed(id: passkey.id) }
            case .failure(let error):
                PasswordFlows.present(error, in: self?.owner?.window)
                reply(WebAuthn.Failure.notAllowed(error.localizedDescription).reply, nil)
            }
        })
    }

    static func label(_ passkey: PasskeyEntry) -> String {
        if passkey.userName.isEmpty { return passkey.displayName ?? "Passkey" }
        if let display = passkey.displayName, display != passkey.userName { return "\(display) (\(passkey.userName))" }
        return passkey.userName
    }
}
