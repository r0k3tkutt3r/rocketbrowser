import Foundation
import WebKit

/// Native WebKit content blocking — the same engine Safari content blockers use.
/// Two independent rule lists: a curated ad/tracker domain blocklist, and cookie-consent
/// banner removal (blocks the big consent-platform CDNs and hides known banner elements).
/// Rules compile once per version and are cached by WKContentRuleListStore.
final class ContentBlocker {

    static let shared = ContentBlocker()

    /// Set by the app delegate: reapplies rules to every open web view and reloads.
    var applyToAllWebViews: (() -> Void)?

    private(set) var adsRuleList: WKContentRuleList?
    private(set) var cookiesRuleList: WKContentRuleList?

    var adsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "BlockAds") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "BlockAds")
            applyToAllWebViews?()
        }
    }

    var cookieBannersHidden: Bool {
        get { UserDefaults.standard.object(forKey: "HideCookieBanners") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "HideCookieBanners")
            applyToAllWebViews?()
        }
    }

    func prepare(completion: @escaping () -> Void) {
        let group = DispatchGroup()
        group.enter()
        Self.load(name: "RocketAds", json: Self.adsJSON) { [weak self] list in
            self?.adsRuleList = list
            group.leave()
        }
        group.enter()
        Self.load(name: "RocketCookies", json: Self.cookiesJSON) { [weak self] list in
            self?.cookiesRuleList = list
            group.leave()
        }
        group.notify(queue: .main, execute: completion)
    }

    /// Installs the enabled rule lists (and the scroll-unlock script) on a web view,
    /// replacing whatever was installed before. Safe to call repeatedly. Incognito
    /// web views get both rule lists and the PrivacyShield scripts regardless of the
    /// user's toggles — re-added here because this method wipes all user scripts, so
    /// a settings toggle can never strip incognito protections. Normal windows get
    /// PrivacyShield too while "Fingerprinting Protection" is on (the default).
    func apply(to webView: WKWebView, isIncognito: Bool = false) {
        let userContent = webView.configuration.userContentController
        userContent.removeAllContentRuleLists()
        userContent.removeAllUserScripts()
        if isIncognito || adsEnabled, let adsRuleList {
            userContent.add(adsRuleList)
        }
        if isIncognito || cookieBannersHidden, let cookiesRuleList {
            userContent.add(cookiesRuleList)
            userContent.addUserScript(WKUserScript(source: Self.scrollUnlockScript,
                                                   injectionTime: .atDocumentEnd,
                                                   forMainFrameOnly: true))
        }
        if isIncognito || PrivacyShield.isEnabled {
            for script in PrivacyShield.userScripts() {
                userContent.addUserScript(script)
            }
        }
        if PromoBlocker.isEnabled {
            for script in PromoBlocker.userScripts() {
                userContent.addUserScript(script)
            }
        }
        // Unconditional, and re-added here for the same reason as PrivacyShield: this
        // method wipes every user script, so a settings toggle must never be able to
        // strip autofill. The "Autofill Passwords" setting is checked natively when a
        // field reports focus — the script still has to run for the toolbar key button
        // and for noticing a login worth saving.
        for script in PasswordAutofill.userScripts() {
            userContent.addUserScript(script)
        }
    }

    // MARK: - Compilation

    private static func load(name: String, json: String, completion: @escaping (WKContentRuleList?) -> Void) {
        guard let store = WKContentRuleListStore.default() else {
            completion(nil)
            return
        }
        let identifier = "\(name)-\(fingerprint(json))"
        // Drop lists compiled from older versions of the rules.
        store.getAvailableContentRuleListIdentifiers { identifiers in
            for stale in identifiers ?? [] where stale.hasPrefix("\(name)-") && stale != identifier {
                store.removeContentRuleList(forIdentifier: stale) { _ in }
            }
        }
        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            if let list {
                completion(list)
                return
            }
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let error {
                    NSLog("Rocket: content rule compile failed for \(name): \(error.localizedDescription)")
                }
                completion(list)
            }
        }
    }

    private static func fingerprint(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return String(hash, radix: 36)
    }

    // MARK: - Rules

    static let adsJSON: String = rulesJSON(
        blockedDomains: [
            // Ad networks and exchanges
            "doubleclick.net", "googlesyndication.com", "googleadservices.com",
            "googletagservices.com", "adservice.google.com", "adnxs.com", "adsrvr.org",
            "adsafeprotected.com", "amazon-adsystem.com", "criteo.com", "criteo.net",
            "outbrain.com", "taboola.com", "rubiconproject.com", "pubmatic.com",
            "openx.net", "casalemedia.com", "indexww.com", "smartadserver.com",
            "teads.tv", "moatads.com", "doubleverify.com", "33across.com",
            "sharethrough.com", "yieldmo.com", "media.net", "mgid.com", "revcontent.com",
            "bidswitch.net", "adform.net", "adroll.com",
            // Trackers, identity graphs, session recorders
            "google-analytics.com", "googletagmanager.com", "scorecardresearch.com",
            "quantserve.com", "quantcount.com", "id5-sync.com", "mathtag.com",
            "bluekai.com", "demdex.net", "omtrdc.net", "everesttech.net", "krxd.net",
            "tapad.com", "rlcdn.com", "liadm.com", "chartbeat.com", "chartbeat.net",
            "hotjar.com", "fullstory.com", "mouseflow.com", "clarity.ms",
            "mixpanel.com", "amplitude.com", "segment.io", "segment.com", "branch.io",
            "nr-data.net",
            // Social pixels
            "connect.facebook.net", "bat.bing.com", "ads-twitter.com",
            "analytics.twitter.com", "analytics.tiktok.com", "ads.linkedin.com",
            "mc.yandex.ru",
        ],
        hiddenSelectors: """
        ins.adsbygoogle, [id^="div-gpt-ad"], [id^="google_ads_iframe"], \
        [id^="taboola-"], .OUTBRAIN, .trc_related_container
        """)

    static let cookiesJSON: String = rulesJSON(
        blockedDomains: [
            "cookielaw.org", "onetrust.com", "cookiebot.com", "privacy-mgmt.com",
            "usercentrics.eu", "privacy-center.org", "cmp.quantcast.com",
            "cmp.inmobi.com", "trustarc.com", "truste.com", "iubenda.com", "termly.io",
            "cookieyes.com", "cdn-cookieyes.com", "osano.com", "cookiefirst.com",
            "cookie-script.com", "consensu.org",
        ],
        hiddenSelectors: """
        #onetrust-consent-sdk, #onetrust-banner-sdk, .onetrust-pc-dark-filter, \
        #CybotCookiebotDialog, #CybotCookiebotDialogBodyUnderlay, #qc-cmp2-container, \
        .qc-cmp2-container, #didomi-host, .didomi-popup-backdrop, #usercentrics-root, \
        div[id^="sp_message_container_"], iframe[id^="sp_message_iframe_"], \
        #truste-consent-track, .truste_box_overlay, .truste_overlay, #consent_blackbar, \
        .cc-window, #cookie-law-info-bar, .cli-modal-backdrop, #cookie-notice, \
        .cookie-notice-container, #gdpr-cookie-message, .cmplz-cookiebanner, \
        #cmplz-cookiebanner-container, #cookiescript_injected, \
        #cookiescript_injected_wrapper, #hs-eu-cookie-confirmation, #iubenda-cs-banner, \
        #CookieBanner, .js-consent-banner
        """)

    private static func rulesJSON(blockedDomains: [String], hiddenSelectors: String) -> String {
        var rules: [[String: Any]] = blockedDomains.map { domain -> [String: Any] in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            let trigger: [String: Any] = [
                "url-filter": "^https?://([^/]+\\.)?\(escaped)[:/]",
                "load-type": ["third-party"],
            ]
            return ["trigger": trigger, "action": ["type": "block"]]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": hiddenSelectors],
        ])
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(data: data, encoding: .utf8)!
    }

    /// Some sites lock page scrolling while their (now hidden) consent banner is up.
    /// If a known consent host is in the DOM, clear the usual scroll locks.
    static let scrollUnlockScript = """
    (function () {
        const cmpSelectors = ['#onetrust-consent-sdk', '#CybotCookiebotDialog',
            '#qc-cmp2-container', '#didomi-host', '#usercentrics-root',
            '[id^="sp_message_container_"]', '#truste-consent-track', '.cc-window',
            '.cmplz-cookiebanner'];
        const lockClasses = ['sp-message-open', 'didomi-popup-open', 'qc-cmp-ui-showing'];
        function unlock() {
            if (!cmpSelectors.some(function (s) { return document.querySelector(s); })) { return; }
            [document.documentElement, document.body].forEach(function (el) {
                if (!el) { return; }
                lockClasses.forEach(function (c) { el.classList.remove(c); });
                if (getComputedStyle(el).overflow === 'hidden') {
                    el.style.setProperty('overflow', 'auto', 'important');
                }
            });
        }
        setTimeout(unlock, 1200);
        setTimeout(unlock, 3200);
    })();
    """
}
