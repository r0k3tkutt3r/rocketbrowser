import Foundation

/// Turns a URL into what the address bar shows when it is not being edited.
/// Focusing the field always reveals the true URL again (see `BrowserWindowController`),
/// so nothing here can hide where you actually are while you edit or copy it.
enum URLDisplay {

    /// Query-parameter names used by the mainstream engines. This is a protocol-level
    /// detail (the name of a query key), not a list of blessed sites — any engine that
    /// uses one of these keys gets the same treatment.
    private static let queryKeys = ["q", "query", "p", "k", "wd", "text", "search_query"]

    /// Keys whose name alone identifies a search, regardless of the path.
    private static let unambiguousKeys: Set<String> = ["search_query"]

    /// `www.` is the only prefix stripped. Deeper subdomains stay visible on purpose:
    /// collapsing `accounts.google.com` (or `paypal.com.attacker.net`) to a bare
    /// registrable domain is exactly the trick phishing pages rely on.
    static func rootDomain(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// The search terms, when the URL looks like a results page.
    static func searchQuery(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, let host = url.host else { return nil }

        // "search" covers most engines, "results" catches YouTube-style result pages,
        // and a bare "/" covers engines that search from the root (DuckDuckGo).
        let path = url.path.lowercased()
        let looksLikeSearch = path.contains("search") || path.contains("results")
            || host.lowercased().hasPrefix("search.")
            || path == "/" || path.isEmpty

        for key in queryKeys {
            guard let value = items.first(where: { $0.name == key })?.value,
                  !value.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // An unambiguous key names itself a search; a generic one like "q" only
            // counts on a search-shaped path, so /article?q=… stays a normal page.
            guard unambiguousKeys.contains(key) || looksLikeSearch else { continue }
            // queryItems percent-decodes but leaves form-encoded "+" as a literal.
            return value.replacingOccurrences(of: "+", with: " ")
        }
        return nil
    }

    /// "google.com — hello" for a search, "example.com" for a normal page,
    /// "" for internal pages (new tab, about:blank) so the field reads as empty.
    static func displayString(for url: URL?) -> String {
        guard let url else { return "" }
        let raw = url.absoluteString
        if raw.isEmpty || raw == "about:blank" { return "" }
        if url.isFileURL { return "" }
        guard let host = url.host, !host.isEmpty else { return raw }

        let domain = rootDomain(host)
        if let query = searchQuery(from: url) {
            return "\(domain) — \(query)"
        }
        return domain
    }
}
