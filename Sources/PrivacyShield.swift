import Foundation
import WebKit

/// Anti-fingerprinting and privacy-signal scripts injected into every incognito page
/// (document start, all frames, page world so sites see the overrides). Modeled on the
/// DuckDuckGo browser's protections. Deliberately NOT spoofed: doNotTrack (Safari
/// removed it — re-adding would distinguish us from Safari), canvas/timezone (high
/// breakage), plugins/deviceMemory/Battery (WebKit is already uniform or lacks them),
/// referrers (WebKit + ITP already trim cross-site referrers to the origin).
enum PrivacyShield {

    static func userScripts() -> [WKUserScript] {
        [WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)]
    }

    /// Every override goes through defineProperty getters so the spoofed values track
    /// reality (screen size follows window resizes) and survive property lookups on
    /// the prototype. try/catch per override: one failure must not disable the rest.
    static let script = """
    (function () {
        'use strict';
        function defineGetter(object, property, getter) {
            try {
                Object.defineProperty(object, property, {
                    get: getter, configurable: true, enumerable: true
                });
            } catch (e) {}
        }

        // Global Privacy Control: the legally binding (CCPA/GDPR) opt-out signal
        // that consent scripts check. Successor to Do Not Track.
        defineGetter(Navigator.prototype, 'globalPrivacyControl', function () { return true; });

        // Hide the real CPU core count; 8 is the most common Safari-on-Mac value,
        // so incognito users blend into the largest crowd.
        defineGetter(Navigator.prototype, 'hardwareConcurrency', function () { return 8; });

        // Display-geometry fingerprint: report the window's own size as the screen
        // size (DuckDuckGo's approach). Sites learn nothing about the display or
        // where the window sits on it.
        defineGetter(Screen.prototype, 'width', function () { return window.innerWidth; });
        defineGetter(Screen.prototype, 'height', function () { return window.innerHeight; });
        defineGetter(Screen.prototype, 'availWidth', function () { return window.innerWidth; });
        defineGetter(Screen.prototype, 'availHeight', function () { return window.innerHeight; });
        defineGetter(Screen.prototype, 'availLeft', function () { return 0; });
        defineGetter(Screen.prototype, 'availTop', function () { return 0; });
        defineGetter(window, 'screenX', function () { return 0; });
        defineGetter(window, 'screenY', function () { return 0; });
        defineGetter(window, 'screenLeft', function () { return 0; });
        defineGetter(window, 'screenTop', function () { return 0; });
        defineGetter(window, 'outerWidth', function () { return window.innerWidth; });
        defineGetter(window, 'outerHeight', function () { return window.innerHeight; });

        // Storage quota is proportional to disk size — a fingerprint. Report a
        // fixed 2 GiB quota and zero usage (the session starts empty anyway).
        if (typeof StorageManager !== 'undefined' && StorageManager.prototype.estimate) {
            try {
                StorageManager.prototype.estimate = function () {
                    return Promise.resolve({ quota: 2147483648, usage: 0 });
                };
            } catch (e) {}
        }
    })();
    """
}
