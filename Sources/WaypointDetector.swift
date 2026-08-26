import Foundation

/// Finds hosts that are *passed through* rather than visited — sign-in redirectors,
/// SSO/OAuth hops, link shorteners, interstitials — so they never become new-tab
/// suggestions. Nothing here names a domain: a host qualifies purely by how it behaves
/// in your own history, so a corporate SSO portal or a URL shortener is caught the same
/// way `accounts.google.com` is.
enum WaypointDetector {

    /// A page you leave this fast was a step on the way somewhere, not a destination.
    static let transientDwellLimit: TimeInterval = 12
    /// A page held this long is a real destination, whatever else it looks like.
    static let destinationDwellFloor: TimeInterval = 30

    struct HostBehavior {
        let host: String
        let visits: Int
        let measuredVisits: Int        // visits whose dwell time is known
        let transientRatio: Double     // share of measured visits under the dwell limit
        let redirectRatio: Double      // share of visits arrived at by redirect
        let authRatio: Double          // share of visits carrying OAuth/SAML parameters
        let destinationVisits: Int     // visits held past the destination floor
        let isWaypoint: Bool
        let reason: String
    }

    /// Query parameters defined by the OAuth 2.0, OpenID Connect, SAML and WS-Federation
    /// specs. Their presence describes the *protocol* a URL is speaking, not the site.
    private static func isAuthShaped(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString),
              let items = components.queryItems else { return false }
        let names = Set(items.map(\.name))
        if !names.isDisjoint(with: ["redirect_uri", "SAMLRequest", "SAMLResponse", "wtrealm",
                                    "RelayState", "oauth_token", "id_token_hint", "code_challenge"]) {
            return true
        }
        // A client id paired with a response type or a continuation target is the
        // classic authorization-endpoint signature.
        if names.contains("client_id") && !names.isDisjoint(with: ["response_type", "continue", "service", "scope"]) {
            return true
        }
        return false
    }

    static func analyze(_ visits: [Visit]) -> [HostBehavior] {
        var byHost: [String: [Visit]] = [:]
        for visit in visits {
            byHost[visit.host, default: []].append(visit)
        }

        return byHost.map { host, hostVisits in
            let measured = hostVisits.compactMap(\.dwell)
            let transient = measured.filter { $0 < transientDwellLimit }.count
            let transientRatio = measured.isEmpty ? 0 : Double(transient) / Double(measured.count)
            let redirectRatio = Double(hostVisits.filter(\.viaRedirect).count) / Double(hostVisits.count)
            let authRatio = Double(hostVisits.filter { isAuthShaped($0.url) }.count) / Double(hostVisits.count)
            let destinationVisits = measured.filter { $0 >= destinationDwellFloor }.count

            var isWaypoint = false
            var reason = ""
            // A host you genuinely spend time on is a destination even if some visits
            // are redirects — this keeps the detector off sites you actually read.
            if destinationVisits < 3 {
                if hostVisits.count >= 2 && authRatio >= 0.5 {
                    isWaypoint = true
                    reason = "sign-in/OAuth parameters on \(Int(authRatio * 100))% of visits"
                } else if measured.count >= 3 && transientRatio >= 0.8 && redirectRatio >= 0.5 {
                    isWaypoint = true
                    reason = "passed through in under \(Int(transientDwellLimit))s on "
                        + "\(Int(transientRatio * 100))% of visits, usually via redirect"
                }
            }

            return HostBehavior(
                host: host, visits: hostVisits.count, measuredVisits: measured.count,
                transientRatio: transientRatio, redirectRatio: redirectRatio, authRatio: authRatio,
                destinationVisits: destinationVisits, isWaypoint: isWaypoint, reason: reason)
        }
        .sorted { $0.host < $1.host }
    }

    static func waypointHosts(in visits: [Visit]) -> Set<String> {
        Set(analyze(visits).filter(\.isWaypoint).map(\.host))
    }
}
