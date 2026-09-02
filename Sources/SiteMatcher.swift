import Foundation

/// Which saved accounts belong to which page. A saved `accounts.google.com` login is
/// offered on `mail.google.com` (same registrable domain), never on
/// `google.com.evil.io`.
///
/// Deliberately not the full Public Suffix List, but the shortcut has a sharp edge
/// worth stating: getting this too NARROW only hides an account, while getting it too
/// BROAD hands one site's password to another. The plain "last two labels" rule is too
/// broad for every multi-label public suffix — it collapses `victim.github.io` and
/// `attacker.github.io` onto `github.io`, and anyone can register the second one for
/// free. `sharedSuffixes` below is therefore a curated list of hosting suffixes where
/// separate registrants live under a common tail, maintained the same way
/// `ContentBlocker`'s blocklists are. Adding to it is always safe; leaving one out is
/// what costs a password.
enum SiteMatcher {

    /// Second-level labels that are themselves public suffixes under a two-letter TLD.
    private static let secondLevelSuffixes: Set<String> = [
        "co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go", "gob", "mil",
    ]

    /// Suffixes under which unrelated people get their own subdomain. A host ending in
    /// one of these keeps one more label than the default rule would give it.
    private static let sharedSuffixes: Set<String> = [
        // Code and static hosting
        "github.io", "gitlab.io", "pages.dev", "workers.dev", "vercel.app",
        "netlify.app", "netlify.com", "herokuapp.com", "herokussl.com", "appspot.com",
        "web.app", "firebaseapp.com", "cloudfunctions.net", "azurewebsites.net",
        "cloudapp.net", "cloudapp.azure.com", "onrender.com", "fly.dev", "railway.app",
        "koyeb.app", "deno.dev", "surge.sh", "neocities.org", "glitch.me", "repl.co",
        "replit.dev", "codesandbox.io", "stackblitz.io", "gitbook.io",
        // Storage and CDN buckets
        "s3.amazonaws.com", "r2.dev", "blob.core.windows.net", "storage.googleapis.com",
        "digitaloceanspaces.com", "backblazeb2.com",
        // Blogging, shops, SaaS tenants
        "blogspot.com", "wordpress.com", "tumblr.com", "medium.com", "substack.com",
        "myshopify.com", "bigcartel.com", "squarespace.com", "wixsite.com",
        "weebly.com", "webflow.io", "zendesk.com", "freshdesk.com", "statuspage.io",
        "atlassian.net", "myjetbrains.com", "notion.site", "framer.website",
        // Tunnels and previews, which attackers reach for first
        "ngrok.io", "ngrok-free.app", "ngrok.app", "trycloudflare.com", "loca.lt",
        "serveo.net", "localtunnel.me", "githubpreview.dev", "gitpod.io",
        // Dynamic DNS
        "duckdns.org", "no-ip.org", "no-ip.com", "ddns.net", "dynu.net", "hopto.org",
        "zapto.org", "sytes.net", "serveblog.net", "myftp.org", "onthewifi.com",
        // Public second levels the two-letter rule misses
        "me.uk", "eu.org", "uk.com", "us.com", "za.com", "de.com", "br.com", "cn.com",
        "sa.com", "se.net", "gb.net", "hu.net", "jp.net", "ru.com", "org.uk", "ltd.uk",
        "plc.uk", "nhs.uk", "sch.uk", "web.id", "or.id", "my.id", "co.nl",
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

        // A shared hosting suffix is checked first and longest-first, so
        // `a.s3.amazonaws.com` keeps three labels rather than being cut to
        // `amazonaws.com` alongside every other bucket.
        for tailLength in stride(from: min(labels.count - 1, 4), through: 2, by: -1) {
            let tail = labels.suffix(tailLength).joined(separator: ".")
            if sharedSuffixes.contains(tail) {
                return labels.suffix(tailLength + 1).joined(separator: ".")
            }
        }

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
