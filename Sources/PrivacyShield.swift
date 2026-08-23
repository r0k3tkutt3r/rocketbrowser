import Foundation
import WebKit

/// Anti-fingerprinting and privacy-signal scripts. Injected into EVERY page while
/// "Fingerprinting Protection" is on (default), and into incognito pages always —
/// (document start, all frames, page world so sites see the overrides). Modeled on the
/// DuckDuckGo and Brave browsers' protections. Deliberately NOT spoofed: doNotTrack
/// (Safari removed it — re-adding would distinguish us from Safari), timezone and
/// fonts (high breakage / needs engine-level support), plugins/deviceMemory/Battery
/// (WebKit is already uniform or lacks them), referrers (WebKit + ITP already trim
/// cross-site referrers to the origin).
///
/// Static overrides make Rocket blend into the Safari crowd (hardwareConcurrency,
/// screen geometry, color depth, WebGL renderer). Canvas and audio can't be made
/// uniform, so they are "farbled" instead (Brave's approach): imperceptible noise
/// seeded per app launch + per site, so those hashes are worthless for tracking —
/// they change on every launch and differ between sites.
enum PrivacyShield {

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "FingerprintProtection") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "FingerprintProtection") }
    }

    /// New noise every launch: a fingerprint that never repeats can't track anyone.
    private static let sessionSeed = UInt32.random(in: UInt32.min...UInt32.max)

    static func userScripts() -> [WKUserScript] {
        [WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false),
         WKUserScript(source: farblingScript.replacingOccurrences(of: "__SEED__", with: String(sessionSeed)),
                      injectionTime: .atDocumentStart, forMainFrameOnly: false)]
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
        // so Rocket users blend into the largest crowd.
        defineGetter(Navigator.prototype, 'hardwareConcurrency', function () { return 8; });

        // Display-geometry fingerprint: report the window's own size as the screen
        // size (DuckDuckGo's approach). Sites learn nothing about the display or
        // where the window sits on it. Color depth is pinned to the most common value.
        defineGetter(Screen.prototype, 'width', function () { return window.innerWidth; });
        defineGetter(Screen.prototype, 'height', function () { return window.innerHeight; });
        defineGetter(Screen.prototype, 'availWidth', function () { return window.innerWidth; });
        defineGetter(Screen.prototype, 'availHeight', function () { return window.innerHeight; });
        defineGetter(Screen.prototype, 'availLeft', function () { return 0; });
        defineGetter(Screen.prototype, 'availTop', function () { return 0; });
        defineGetter(Screen.prototype, 'colorDepth', function () { return 24; });
        defineGetter(Screen.prototype, 'pixelDepth', function () { return 24; });
        defineGetter(window, 'screenX', function () { return 0; });
        defineGetter(window, 'screenY', function () { return 0; });
        defineGetter(window, 'screenLeft', function () { return 0; });
        defineGetter(window, 'screenTop', function () { return 0; });
        defineGetter(window, 'outerWidth', function () { return window.innerWidth; });
        defineGetter(window, 'outerHeight', function () { return window.innerHeight; });

        // Storage quota is proportional to disk size — a fingerprint. Report a
        // fixed 2 GiB quota and zero usage.
        if (typeof StorageManager !== 'undefined' && StorageManager.prototype.estimate) {
            try {
                StorageManager.prototype.estimate = function () {
                    return Promise.resolve({ quota: 2147483648, usage: 0 });
                };
            } catch (e) {}
        }

        // WebGL debug strings: report the uniform values modern Safari uses for
        // every Mac instead of the real GPU model.
        function wrapGL(contextClass) {
            if (!contextClass || !contextClass.prototype || !contextClass.prototype.getParameter) { return; }
            try {
                const original = contextClass.prototype.getParameter;
                contextClass.prototype.getParameter = function (parameter) {
                    if (parameter === 0x9245) { return 'Apple Inc.'; }   // UNMASKED_VENDOR_WEBGL
                    if (parameter === 0x9246) { return 'Apple GPU'; }    // UNMASKED_RENDERER_WEBGL
                    return original.call(this, parameter);
                };
            } catch (e) {}
        }
        wrapGL(window.WebGLRenderingContext);
        wrapGL(window.WebGL2RenderingContext);
    })();
    """

    /// Canvas + audio farbling. These readouts hash the exact rendering of the user's
    /// GPU/CPU — impossible to make uniform, so we make them unstable instead:
    /// flip a sparse scattering of least-significant bits, deterministic within one
    /// app launch and one site (repeated reads agree, so sites don't glitch), but
    /// different across launches and across sites (no stable ID, no cross-site link).
    static let farblingScript = """
    (function () {
        'use strict';
        function mulberry32(seed) {
            let a = seed >>> 0;
            return function () {
                a |= 0; a = a + 0x6D2B79F5 | 0;
                let t = Math.imul(a ^ a >>> 15, 1 | a);
                t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
                return ((t ^ t >>> 14) >>> 0) / 4294967296;
            };
        }
        let originHash = 0;
        try {
            const s = location.origin || '';
            for (let i = 0; i < s.length; i++) { originHash = (originHash * 31 + s.charCodeAt(i)) | 0; }
        } catch (e) {}
        const SEED = (__SEED__ ^ originHash) >>> 0;

        // ---- Canvas: flip ~1 LSB per 64 pixels on RGB channels before readback.
        function noiseImageData(data, width, height) {
            const pixels = width * height;
            if (!pixels) { return; }
            const rng = mulberry32(SEED ^ ((width * 7919 + height * 104729) >>> 0));
            const count = Math.max(16, Math.floor(pixels / 64));
            for (let i = 0; i < count; i++) {
                const p = Math.floor(rng() * pixels);
                data[p * 4 + Math.floor(rng() * 3)] ^= 1;
            }
        }

        const origGetImageData = CanvasRenderingContext2D.prototype.getImageData;
        CanvasRenderingContext2D.prototype.getImageData = function (x, y, w, h) {
            const result = origGetImageData.apply(this, arguments);
            try { noiseImageData(result.data, result.width, result.height); } catch (e) {}
            return result;
        };

        // toDataURL / toBlob: encode a noised CLONE so the on-screen canvas is untouched.
        function noisedClone(canvas) {
            try {
                const context = canvas.getContext('2d');
                if (!context || !canvas.width || !canvas.height) { return null; }
                const data = origGetImageData.call(context, 0, 0, canvas.width, canvas.height);
                noiseImageData(data.data, data.width, data.height);
                const clone = document.createElement('canvas');
                clone.width = canvas.width;
                clone.height = canvas.height;
                clone.getContext('2d').putImageData(data, 0, 0);
                return clone;
            } catch (e) { return null; }
        }
        const origToDataURL = HTMLCanvasElement.prototype.toDataURL;
        HTMLCanvasElement.prototype.toDataURL = function () {
            const clone = noisedClone(this);
            return origToDataURL.apply(clone || this, arguments);
        };
        const origToBlob = HTMLCanvasElement.prototype.toBlob;
        HTMLCanvasElement.prototype.toBlob = function (callback) {
            const clone = noisedClone(this);
            if (clone) {
                const args = Array.prototype.slice.call(arguments);
                return origToBlob.apply(clone, args);
            }
            return origToBlob.apply(this, arguments);
        };

        // ---- Audio: ±1e-7 on sparse samples of offline renders (inaudible; offline
        // rendering is what fingerprint scripts hash). Live playback is untouched.
        if (window.OfflineAudioContext) {
            try {
                const origStartRendering = OfflineAudioContext.prototype.startRendering;
                OfflineAudioContext.prototype.startRendering = function () {
                    return origStartRendering.call(this).then(function (buffer) {
                        try {
                            const rng = mulberry32(SEED ^ 0xa0d10);
                            for (let c = 0; c < buffer.numberOfChannels; c++) {
                                const channel = buffer.getChannelData(c);
                                for (let i = 0; i < channel.length; i += 500) {
                                    channel[i] += (rng() - 0.5) * 1e-7;
                                }
                            }
                        } catch (e) {}
                        return buffer;
                    });
                };
            } catch (e) {}
        }
    })();
    """
}
