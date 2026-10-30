import Foundation

struct AddressSuggestion: Equatable {
    enum Kind { case search, history, bookmark }
    let kind: Kind
    let title: String
    let subtitle: String?
    let url: URL

    var symbolName: String {
        switch kind {
        case .search: return "magnifyingglass"
        case .history: return "clock"
        case .bookmark: return "star"
        }
    }
}

/// Builds the address bar's suggestion list: local history and bookmarks (always
/// available, never leaves the Mac) plus the search engine's own completions, which
/// are only fetched when "Search Suggestions" is on.
enum AddressSuggestionProvider {

    static var remoteEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "SearchSuggestions") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "SearchSuggestions") }
    }

    /// History + bookmarks, matched on host, URL and title. Synchronous and offline.
    static func local(for text: String, limit: Int = 4) -> [AddressSuggestion] {
        let needle = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var results: [AddressSuggestion] = []
        var seen = Set<String>()

        for bookmark in flatten(BookmarkStore.shared.items) {
            guard let urlString = bookmark.url, let url = URL(string: urlString) else { continue }
            guard bookmark.title.lowercased().contains(needle) || urlString.lowercased().contains(needle) else { continue }
            guard seen.insert(urlString).inserted else { continue }
            results.append(AddressSuggestion(kind: .bookmark, title: bookmark.title,
                                             subtitle: URLDisplay.rootDomain(url.host ?? urlString), url: url))
            if results.count >= limit { return results }
        }

        // Ranked by how much you actually use each page, so a page you opened once and
        // abandoned cannot outrank the site itself.
        for candidate in HistoryRanker.matches(for: needle, in: HistoryStore.shared.visits, limit: limit) {
            guard let url = URL(string: candidate.url), seen.insert(candidate.url).inserted else { continue }
            results.append(AddressSuggestion(kind: .history,
                                             title: URLDisplay.rootDomain(candidate.host),
                                             subtitle: candidate.detail, url: url))
            if results.count >= limit { break }
        }
        return results
    }

    private static func flatten(_ items: [Bookmark]) -> [Bookmark] {
        items.flatMap { item -> [Bookmark] in
            if let children = item.children { return flatten(children) }
            return [item]
        }
    }

    /// A connection kept warm for completions only. Ephemeral so these keystroke
    /// requests carry no cookies, and configured for latency rather than throughput:
    /// one reused HTTP/2 connection, short timeout, no disk cache in the way.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 3
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    /// Completions already fetched this session, keyed by query. Typing forward and
    /// backspacing both replay through here, which is what makes editing feel instant
    /// instead of re-hitting the network for a prefix already seen.
    private static var cache: [String: [String]] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheLimit = 300

    static func cached(for text: String) -> [String]? {
        cache[cacheKey(text)]
    }

    private static func cacheKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func store(_ completions: [String], for text: String) {
        let key = cacheKey(text)
        if cache[key] == nil {
            cacheOrder.append(key)
            if cacheOrder.count > cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        cache[key] = completions
    }

    /// The engine's own completions. Private windows ask DuckDuckGo, matching the
    /// private-search choice, so incognito typing never reaches Google.
    @discardableResult
    static func remote(for text: String, privateSearch: Bool,
                       completion: @escaping ([String]) -> Void) -> URLSessionDataTask? {
        guard remoteEnabled else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }

        // Answer from cache in this same runloop turn — no network, no waiting.
        if let hit = cache[cacheKey(text)] {
            completion(hit)
            return nil
        }

        let endpoint = privateSearch
            ? "https://duckduckgo.com/ac/?type=list&q=\(encoded)"
            : "https://suggestqueries.google.com/complete/search?client=firefox&q=\(encoded)"
        guard let url = URL(string: endpoint) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.assumesHTTP3Capable = true
        let task = session.dataTask(with: request) { data, _, _ in
            // Both engines answer with ["typed text", ["suggestion", …]].
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  root.count > 1, let list = root[1] as? [String] else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            DispatchQueue.main.async {
                store(list, for: text)
                completion(list)
            }
        }
        task.resume()
        return task
    }
}

/// The address bar's typing loop, shared by the Mac and iOS apps. Local matches
/// render on every keystroke; at most one engine request is in flight, and the
/// newest query typed meanwhile fires the moment it lands. There is deliberately no
/// debounce — with one, nothing arrived until typing stopped.
final class AddressCompleter {

    var privateSearch: Bool
    /// The field's live text while it is being edited, nil otherwise, so a late
    /// answer never redraws a list the user has already left.
    private let editingText: () -> String?
    /// Receives the list to draw; an empty list means hide it.
    private let render: ([AddressSuggestion]) -> Void

    /// Completion request currently on the wire, and the newest query typed while it
    /// was in flight. The newest text always wins.
    private var inFlightQuery: String?
    private var pendingQuery: String?
    /// The last completions received, reused while a newer request is in flight so the
    /// list keeps its shape instead of collapsing between keystrokes.
    private var lastRemoteQuery: String?
    private var lastRemoteItems: [String] = []

    init(privateSearch: Bool, editingText: @escaping () -> String?,
         render: @escaping ([AddressSuggestion]) -> Void) {
        self.privateSearch = privateSearch
        self.editingText = editingText
        self.render = render
    }

    func update(for text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            lastRemoteQuery = nil
            lastRemoteItems = []
            render([])
            return
        }
        // Draw on this keystroke, from local data plus any completions already known.
        render(suggestions(for: text))
        requestRemote(for: text)
    }

    /// Everything that can be shown without waiting: bookmarks, history, the literal
    /// typed text, and cached (or carried-forward) engine completions.
    private func suggestions(for text: String) -> [AddressSuggestion] {
        var results = AddressSuggestionProvider.local(for: text)
        // The literal typed text always leads, so Return does what it looks like.
        if let direct = URLResolver.resolve(text, privateSearch: privateSearch) {
            let isSearch = URLDisplay.searchQuery(from: direct) != nil
            results.insert(AddressSuggestion(kind: isSearch ? .search : .history,
                                             title: text,
                                             subtitle: isSearch ? "Search" : "Open",
                                             url: direct), at: 0)
        }

        // Exact completions if we have them; otherwise keep showing the previous
        // query's completions while they are still a plausible prefix, so the list
        // stays populated as the user keeps typing.
        var completions = AddressSuggestionProvider.cached(for: text)
        if completions == nil, let previous = lastRemoteQuery,
           text.lowercased().hasPrefix(previous.lowercased()) {
            completions = lastRemoteItems
        }
        for completion in (completions ?? []).prefix(5) {
            guard !results.contains(where: { $0.title.caseInsensitiveCompare(completion) == .orderedSame }),
                  let url = URLResolver.resolve(completion, privateSearch: privateSearch) else { continue }
            results.append(AddressSuggestion(kind: .search, title: completion, subtitle: nil, url: url))
        }
        return results
    }

    private func requestRemote(for text: String) {
        if let hit = AddressSuggestionProvider.cached(for: text) {
            lastRemoteQuery = text
            lastRemoteItems = hit
            return                                  // already rendered from cache
        }
        guard inFlightQuery == nil else {
            pendingQuery = text
            return
        }
        inFlightQuery = text
        let task = AddressSuggestionProvider.remote(for: text, privateSearch: privateSearch) { [weak self] completions in
            guard let self else { return }
            self.inFlightQuery = nil
            if !completions.isEmpty {
                self.lastRemoteQuery = text
                self.lastRemoteItems = completions
            }
            if let current = self.editingText(), current == text {
                self.render(self.suggestions(for: current))
            }
            if let pending = self.pendingQuery {
                self.pendingQuery = nil
                if pending != text { self.requestRemote(for: pending) }
            }
        }
        // No request went out (suggestions off, or unencodable text) and none will
        // call back — without this the slot stayed taken for the life of the tab, so
        // turning Search Suggestions back on did nothing until the tab was reopened.
        if task == nil, inFlightQuery == text { inFlightQuery = nil }
    }
}
