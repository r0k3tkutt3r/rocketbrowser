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

/// Turns address-bar input into a URL: direct URLs load as-is, bare hosts get https://,
/// everything else becomes a search query — Google normally, Brave Search (which
/// doesn't profile searches) in incognito windows.
enum URLResolver {
    static func resolve(_ input: String, privateSearch: Bool = false) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = subreddit(text) { return url }
        if let url = googleShortcut(text) { return url }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme) {
            return url
        }

        let looksLikeHost = !text.contains(" ")
            && (text.contains(".") || text.hasPrefix("localhost"))
        if looksLikeHost {
            let scheme = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") ? "http" : "https"
            if let url = URL(string: "\(scheme)://\(text)") { return url }
        }

        var components = URLComponents(string: privateSearch
            ? "https://search.brave.com/search" : "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }

    /// "g/docs" opens docs.google.com. Unknown names fall through to a search.
    static let googleServices: [String: String] = [
        "docs": "docs", "drive": "drive", "slides": "slides", "sheets": "sheets",
        "forms": "forms", "maps": "maps", "mail": "mail", "gmail": "mail",
        "calendar": "calendar", "cal": "calendar", "meet": "meet", "photos": "photos",
        "keep": "keep", "translate": "translate", "news": "news", "contacts": "contacts",
        "gemini": "gemini", "chat": "chat", "sites": "sites", "scholar": "scholar",
        "earth": "earth", "play": "play", "account": "myaccount", "analytics": "analytics",
        "cloud": "console.cloud", "colab": "colab.research",
    ]

    static func googleShortcut(_ text: String) -> URL? {
        guard text.lowercased().hasPrefix("g/") else { return nil }
        let name = text.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard let sub = googleServices[name] else { return nil }
        return URL(string: "https://\(sub).google.com")
    }

    /// "r/claude" opens the subreddit; "r/claude best skills" searches inside it.
    static func subreddit(_ text: String) -> URL? {
        guard text.lowercased().hasPrefix("r/") else { return nil }
        let rest = text.dropFirst(2)
        let name = rest.prefix { !$0.isWhitespace }
        guard !name.isEmpty,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        else { return nil }
        let query = rest.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return URL(string: "https://www.reddit.com/r/\(name)") }
        var components = URLComponents(string: "https://www.reddit.com/r/\(name)/search/")!
        components.queryItems = [URLQueryItem(name: "q", value: query),
                                 URLQueryItem(name: "restrict_sr", value: "1")]
        return components.url
    }
}

func htmlEscaped(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
