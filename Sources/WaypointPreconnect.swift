import Foundation
import WebKit

/// Warms the connection to the host a sign-in hop is about to hand you to, so the TLS
/// handshake is already paid for when the redirect fires.
///
/// Rocket cannot know the *URL* an OAuth redirector will produce — that depends on the
/// server's session, not on anything the browser can see. It does know, from your own
/// history, which host almost always follows this one, and a connection is all the next
/// hop actually needs early. `rel="preconnect"` is WebKit's native primitive for this;
/// measured against a local listener it opens the TCP connection and sends no request
/// bytes, which is exactly the part worth doing ahead of time.
///
/// Restricted to hosts `WaypointDetector` already flagged as pass-throughs. That is where
/// the wait is felt, and it stops the browser announcing itself to hosts you were merely
/// reading about. Never runs in incognito: the prediction is drawn from normal browsing
/// history, and connecting on its say-so would carry that history into a private session.
enum WaypointPreconnect {

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "PreconnectNextHop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "PreconnectNextHop") }
    }

    /// A transition has to be this consistent, over at least this many observations,
    /// before the next host counts as predictable rather than coincidental.
    static let minimumObservations = 3
    static let minimumShare = 0.5
    /// A redirect lands in seconds. A visit further out than this is the next thing you
    /// did, not the place the hop was taking you.
    static let followWindow: TimeInterval = 300

    /// The host that most often follows `host` within `followWindow`, or nil when your
    /// history has no clear answer.
    static func nextHost(after host: String, in visits: [Visit], waypoints: Set<String>) -> String? {
        guard waypoints.contains(host) else { return nil }
        let ordered = visits.sorted { $0.ts < $1.ts }
        var counts: [String: Int] = [:]
        for (previous, next) in zip(ordered, ordered.dropFirst())
        where previous.host == host && next.host != host
            && next.ts.timeIntervalSince(previous.ts) <= followWindow {
            counts[next.host, default: 0] += 1
        }
        let total = counts.values.reduce(0, +)
        guard total >= minimumObservations,
              let best = counts.max(by: { $0.value < $1.value }),
              Double(best.value) / Double(total) >= minimumShare else { return nil }
        return best.key
    }

    /// `WaypointDetector.analyze` parses every URL in the history, and this runs on every
    /// page load, so the answer is held for a while. Ten minutes is nothing against the
    /// weeks of history it is derived from.
    private static let cacheLifetime: TimeInterval = 10 * 60
    private static var cachedWaypoints: (hosts: Set<String>, at: Date)?

    static func waypoints(now: Date = Date()) -> Set<String> {
        if let cached = cachedWaypoints, now.timeIntervalSince(cached.at) < cacheLifetime {
            return cached.hosts
        }
        let hosts = WaypointDetector.waypointHosts(in: HistoryStore.shared.visits)
        cachedWaypoints = (hosts, now)
        return hosts
    }

    /// Hands the page the browser's own preconnect hint. The host rides as a
    /// `callAsyncJavaScript` argument rather than spliced into source — the same rule
    /// autofill follows — and runs in the client's isolated world, so the page can
    /// neither read nor rewrite the hint.
    static func preconnect(from webView: WKWebView, on host: String) {
        guard isEnabled,
              let next = nextHost(after: host, in: HistoryStore.shared.visits,
                                  waypoints: waypoints()) else { return }
        webView.callAsyncJavaScript("""
            const link = document.createElement('link');
            link.rel = 'preconnect';
            link.href = 'https://' + host;
            link.crossOrigin = '';
            document.head.appendChild(link);
            """, arguments: ["host": next], in: nil, in: .defaultClient)
    }

    // MARK: - Hovered links

    /// The other half of the same idea, and the half that fires far more often: warm the
    /// connection to a link while the pointer is still resting on it, so the handshake is
    /// already paid for by the time it is clicked.
    ///
    /// This lives entirely in the page rather than reporting hovers to native. The
    /// decision needs nothing the browser knows, and a round trip through a message
    /// handler would add latency to a feature whose whole purpose is removing it — it
    /// would also hand the page a way to tell Rocket about hovers that never happened.
    ///
    /// Hovering does mean connecting to a host you may never visit. That is the cost of
    /// the feature and the reason it has a switch; it is also why it stays out of
    /// incognito, where "I looked at this link" is exactly what nobody should learn.
    static func userScripts() -> [WKUserScript] {
        [WKUserScript(source: hoverScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)]
    }

    static let hoverScript = """
    (function () {
        'use strict';
        // Long enough that sweeping the pointer across a navigation bar warms nothing,
        // short enough to be done before a deliberate click lands.
        const HOVER_DELAY = 120;
        // A page of 500 links must not open 500 connections.
        const MAX_ORIGINS = 12;

        const warmed = new Set();
        let timer = 0;

        function warm(origin) {
            if (warmed.has(origin) || warmed.size >= MAX_ORIGINS) { return; }
            warmed.add(origin);
            const link = document.createElement('link');
            link.rel = 'preconnect';
            link.href = origin;
            link.crossOrigin = '';
            (document.head || document.documentElement).appendChild(link);
        }

        document.addEventListener('mouseover', function (event) {
            // Same rule as autofill: events reach every content world, and a page that
            // could forge these could open connections nobody asked for.
            if (!event.isTrusted) { return; }
            clearTimeout(timer);
            const anchor = event.target && event.target.closest
                ? event.target.closest('a[href]') : null;
            if (!anchor) { return; }
            let origin;
            try {
                const url = new URL(anchor.href, location.href);
                if (url.protocol !== 'https:' && url.protocol !== 'http:') { return; }
                origin = url.origin;
            } catch (e) { return; }
            // The page's own origin is already connected; preconnecting it is all cost.
            if (origin === location.origin) { return; }
            timer = setTimeout(function () { warm(origin); }, HOVER_DELAY);
        }, true);

        document.addEventListener('mouseout', function () { clearTimeout(timer); }, true);
    })();
    """
}
