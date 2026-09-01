import Cocoa

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

/// Borderless panel under the address bar. It never becomes key, so typing keeps
/// flowing into the URL field while the list updates underneath.
final class SuggestionsDropdown {

    var onAccept: ((AddressSuggestion) -> Void)?

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 0),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
    private let stack = NSStackView()
    private var rows: [SuggestionRow] = []
    private(set) var suggestions: [AddressSuggestion] = []
    private(set) var selectedIndex: Int?
    private weak var anchor: NSView?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        panel.contentView = background
    }

    func show(_ suggestions: [AddressSuggestion], below field: NSView) {
        guard !suggestions.isEmpty, let window = field.window else {
            hide()
            return
        }
        self.suggestions = suggestions
        self.anchor = field
        if let selectedIndex, selectedIndex >= suggestions.count { self.selectedIndex = nil }

        // Reuse row views: this runs on every keystroke and on every batch of
        // completions, so rebuilding the view tree each time showed up as a stutter.
        while rows.count < suggestions.count {
            let row = SuggestionRow { [weak self] index in
                self?.accept(at: index)
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 30).isActive = true
            rows.append(row)
        }
        while rows.count > suggestions.count {
            rows.removeLast().removeFromSuperview()
        }
        for (index, suggestion) in suggestions.enumerated() {
            rows[index].update(with: suggestion, index: index)
        }
        highlightSelection()

        let fieldFrame = field.convert(field.bounds, to: nil)
        let origin = window.convertPoint(toScreen: NSPoint(x: fieldFrame.minX, y: fieldFrame.minY))
        let height = CGFloat(suggestions.count) * 30 + 8
        panel.setFrame(NSRect(x: origin.x, y: origin.y - height - 3,
                              width: fieldFrame.width, height: height), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        selectedIndex = nil
        suggestions = []
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Returns the newly selected suggestion so the caller can preview it in the field.
    @discardableResult
    func moveSelection(by delta: Int) -> AddressSuggestion? {
        guard !suggestions.isEmpty else { return nil }
        let next: Int
        switch selectedIndex {
        case nil: next = delta > 0 ? 0 : suggestions.count - 1
        case let current?: next = current + delta
        }
        selectedIndex = next < 0 || next >= suggestions.count ? nil : next
        highlightSelection()
        return selectedIndex.map { suggestions[$0] }
    }

    var selectedSuggestion: AddressSuggestion? {
        selectedIndex.map { suggestions[$0] }
    }

    private func highlightSelection() {
        for (index, row) in rows.enumerated() {
            row.isHighlighted = index == selectedIndex
        }
    }

    private func accept(at index: Int) {
        guard index < suggestions.count else { return }
        let suggestion = suggestions[index]
        hide()
        onAccept?(suggestion)
    }
}

/// A single suggestion row; highlights on hover and on keyboard selection.
final class SuggestionRow: NSView {

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let onClick: (Int) -> Void
    private var index = 0

    var isHighlighted = false {
        didSet {
            layer?.backgroundColor = isHighlighted
                ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor
            titleLabel.textColor = isHighlighted ? .white : .labelColor
            subtitleLabel.textColor = isHighlighted ? .white.withAlphaComponent(0.8) : .secondaryLabelColor
            iconView.contentTintColor = isHighlighted ? .white : .secondaryLabelColor
        }
    }

    init(onClick: @escaping (Int) -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true

        iconView.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 12.5)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        for view in [iconView, titleLabel, subtitleLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            subtitleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self)
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Swaps in new content without rebuilding the view or its constraints.
    func update(with suggestion: AddressSuggestion, index: Int) {
        self.index = index
        iconView.image = NSImage(systemSymbolName: suggestion.symbolName, accessibilityDescription: nil)
        if titleLabel.stringValue != suggestion.title { titleLabel.stringValue = suggestion.title }
        let subtitle = suggestion.subtitle ?? ""
        if subtitleLabel.stringValue != subtitle { subtitleLabel.stringValue = subtitle }
    }

    override func mouseEntered(with event: NSEvent) { isHighlighted = true }
    override func mouseExited(with event: NSEvent) { isHighlighted = false }
    override func mouseDown(with event: NSEvent) { onClick(index) }
}
