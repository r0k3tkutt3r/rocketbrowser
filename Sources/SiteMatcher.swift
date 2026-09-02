import Foundation

/// Which saved accounts belong to which page. A saved `accounts.google.com` login is
/// offered on `mail.google.com` (same registrable domain), never on
/// `google.com.evil.io`. Deliberately not a full public-suffix list: the two-label
/// rule plus the common `co.uk`-style second levels covers real logins, and a
/// mistake here only hides an account, it never leaks one to a stranger domain.
enum SiteMatcher {

    /// Second-level labels that are themselves public suffixes under a two-letter TLD.
    private static let secondLevelSuffixes: Set<String> = [
        "co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go", "gob", "mil",
    ]

    /// Lowercased host with the port kept when it is not the scheme's default.
    static func host(from url: URL) -> String? {
        guard let raw = url.host, !raw.isEmpty else { return nil }
        let host = raw.lowercased()
        if let port = url.port {
            let isDefault = (url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)
            if !isDefault { return "\(host):\(port)" }
        }
        return host
    }

    static func registrableDomain(of host: String) -> String {
        let bare = stripWWW(host)
        if bare.contains(":") || isIPAddress(bare) || !bare.contains(".") { return bare }
        let labels = bare.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return bare }
        let tld = labels[labels.count - 1]
        let second = labels[labels.count - 2]
        if tld.count == 2, secondLevelSuffixes.contains(second) {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    static func matches(entryHost: String, pageHost: String) -> Bool {
        registrableDomain(of: entryHost) == registrableDomain(of: pageHost)
    }

    static func isExact(entryHost: String, pageHost: String) -> Bool {
        stripWWW(entryHost) == stripWWW(pageHost)
    }

    static func displayHost(_ host: String) -> String { stripWWW(host) }

    /// Exact-host matches first, then the rest of the domain; most recently used first
    /// inside each group, so the account you used last is the one under the cursor.
    static func rank(entries: [PasswordEntry], forPageHost pageHost: String) -> [PasswordEntry] {
        let matching = entries.filter { matches(entryHost: $0.host, pageHost: pageHost) }
        return matching.sorted { lhs, rhs in
            let le = isExact(entryHost: lhs.host, pageHost: pageHost)
            let re = isExact(entryHost: rhs.host, pageHost: pageHost)
            if le != re { return le }
            let lu = lhs.lastUsed ?? .distantPast
            let ru = rhs.lastUsed ?? .distantPast
            if lu != ru { return lu > ru }
            return lhs.username.lowercased() < rhs.username.lowercased()
        }
    }

    private static func stripWWW(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    private static func isIPAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
