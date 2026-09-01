import Foundation
import WebKit

/// Removes "install Chrome" interstitials from Google's properties.
///
/// Google rotates the class names and element ids on these cards constantly, so
/// matching them by selector goes stale within weeks. This matches on what the card
/// *is* instead: a small block of content that pitches a browser by name and offers a
/// way to install it. That shape survives the markup churn, and it catches the same
/// nag on Search, Gmail, Docs, Drive, YouTube and the rest without naming any of them.
enum PromoBlocker {

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "HideBrowserPromos") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "HideBrowserPromos") }
    }

    static func userScripts() -> [WKUserScript] {
        [WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false)]
    }

    static let script = """
    (function () {
        'use strict';

        // Links that exist to install a browser.
        const INSTALL_LINK = /(google\\.[a-z.]{2,10}\\/(intl\\/[^/]+\\/)?chrome)|(^|\\/\\/)chrome\\.google\\.com|google\\.[a-z.]{2,10}\\/chrome/i;
        // Phrases precise enough that a page using one is pitching a browser, not
        // merely mentioning one. "Chrome" alone is deliberately not enough.
        const PITCH = new RegExp([
            'choose chrome', 'browser built by google', 'try chrome', 'get chrome',
            'download chrome', 'switch to chrome', 'install chrome',
            'make chrome your default', 'chrome your default browser',
            'faster with chrome', 'get the chrome browser'
        ].join('|'), 'i');

        // Never touch a page whose actual purpose is downloading a browser.
        function onADownloadPage() {
            const host = location.hostname, path = location.pathname;
            if (/(^|\\.)chrome\\.google\\.com$/i.test(host)) { return true; }
            if (/(^|\\.)google\\.[a-z.]{2,10}$/i.test(host) && /^\\/(intl\\/[^/]+\\/)?chrome/i.test(path)) {
                return true;
            }
            return false;
        }
        if (onADownloadPage()) { return; }

        // Walk up from the pitch to the card that contains it, stopping before the
        // element grows into real page content. This is the guard that keeps the
        // script from eating an article that happens to discuss Chrome.
        const MAX_CARD_TEXT = 400;
        const MAX_DEPTH = 8;
        function enclosingCard(node) {
            let element = node instanceof Element ? node : node.parentElement;
            let card = null, depth = 0;
            while (element && element !== document.body
                   && element !== document.documentElement && depth < MAX_DEPTH) {
                const text = (element.textContent || '').trim();
                if (text.length > MAX_CARD_TEXT) { break; }
                // Keep climbing while the block still looks card-sized.
                card = element;
                element = element.parentElement;
                depth++;
            }
            return card;
        }

        const PROTECTED = new Set(['BODY', 'HTML', 'MAIN', 'ARTICLE', 'HEAD']);
        function drop(element) {
            if (!element || PROTECTED.has(element.tagName)) { return false; }
            if (element.dataset && element.dataset.rocketPromoHandled) { return false; }
            // A promo occupying most of the viewport is a takeover, but so is the page
            // itself — refuse anything that is plainly the main content.
            const rect = element.getBoundingClientRect();
            const viewport = window.innerWidth * window.innerHeight;
            if (viewport > 0 && rect.width * rect.height > viewport * 0.8
                && (element.textContent || '').length > MAX_CARD_TEXT / 2) {
                return false;
            }
            element.dataset.rocketPromoHandled = '1';
            element.style.setProperty('display', 'none', 'important');
            return true;
        }

        function sweep(root) {
            let removed = 0;
            const scope = root && root.querySelectorAll ? root : document;

            // 1. Anything offering an install link, inside a card-sized block.
            scope.querySelectorAll('a[href]').forEach(function (anchor) {
                if (!INSTALL_LINK.test(anchor.getAttribute('href') || '')) { return; }
                const card = enclosingCard(anchor);
                if (!card) { return; }
                const text = (card.textContent || '');
                // An install link inside a genuine pitch, or a bare promo card.
                if (PITCH.test(text) || text.trim().length < 120) {
                    if (drop(card)) { removed++; }
                }
            });

            // 2. Pitches whose button is scripted rather than a link (the "Try it"
            //    dialogs), found by their text and confirmed by having a control.
            const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT, null);
            const hits = [];
            let node;
            while ((node = walker.nextNode())) {
                const value = node.nodeValue;
                if (value && value.length < 200 && PITCH.test(value)) { hits.push(node); }
            }
            hits.forEach(function (textNode) {
                const card = enclosingCard(textNode);
                if (!card) { return; }
                const interactive = card.querySelector('a, button, [role="button"]');
                if (!interactive) { return; }
                if (drop(card)) { removed++; }
            });
            return removed;
        }

        sweep(document);
        // These cards are injected well after load, and re-injected after dismissal.
        let scheduled = false;
        const observer = new MutationObserver(function () {
            if (scheduled) { return; }
            scheduled = true;
            // A timer rather than requestAnimationFrame: rAF is suspended while a view
            // is not rendering, so promos in a background tab would survive until it
            // was brought forward.
            setTimeout(function () { scheduled = false; sweep(document); }, 50);
        });
        observer.observe(document.documentElement, { childList: true, subtree: true });
    })();
    """
}
