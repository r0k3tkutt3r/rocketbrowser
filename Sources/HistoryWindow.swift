import Cocoa

/// One visit in the history list: title, host/path (or the search terms), and the time.
final class HistoryRowView: NSTableCellView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        // The middle of a long URL is the throwaway part; the host and the last path
        // component are what identify the page.
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.alignment = .right

        for label in [titleLabel, subtitleLabel, timeLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        // The time never truncates or gets shoved off the edge by a long title.
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with visit: Visit) {
        titleLabel.stringValue = visit.displayTitle
        subtitleLabel.stringValue = HistoryGrouping.subtitle(for: visit)
        timeLabel.stringValue = HistoryGrouping.timeLabel(for: visit.ts)
        toolTip = visit.url
    }
}

/// A date header ("Today", "Friday", "August 1, 2026").
final class HistoryHeaderRowView: NSTableCellView {

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) { label.stringValue = title }
}

/// `NSTableView` does not turn ⌫ into a delete action by itself, and whether an
/// unhandled key reaches the window controller depends on responder-chain details
/// that are easy to get subtly wrong. Catching it here makes it unambiguous.
final class HistoryTableView: NSTableView {

    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]   // delete, forward delete
        if deleteKeys.contains(event.keyCode), !selectedRowIndexes.isEmpty {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
}

/// The history window: search, date-grouped visits, delete, clear.
///
/// This exists because `HistoryRanker` deliberately keeps one-off deep URLs out of the
/// address bar. That is right for completions and wrong for recall, so search here is
/// a plain substring match over everything (see `HistoryGrouping.matches`).
final class HistoryWindowController: NSWindowController {

    static let shared = HistoryWindowController()

    private let tableView = HistoryTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private var rows: [HistoryGrouping.Row] = []
    private var observer: NSObjectProtocol?
    /// Deleting rows one at a time would otherwise kick off a training pass per click.
    private var pendingRetrain: DispatchWorkItem?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "History"
        window.minSize = NSSize(width: 420, height: 300)
        // The shared controller outlives every close, so the window must not be
        // deallocated out from under it when the user hits the red button.
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("RocketHistoryWindow")
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Building

    private func buildContent() {
        guard let window else { return }
        let container = NSView()

        searchField.placeholderString = "Search History"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        // Fire per keystroke rather than only on Return.
        searchField.sendsWholeSearchString = false
        // Filtering a few thousand visits costs far less than a frame, so there is no
        // reason to make the user wait out a debounce to see their own history.
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.style = .inset
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelection)
        tableView.menu = buildContextMenu()
        tableView.onDelete = { [weak self] in self?.deleteSelection() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        clearButton.title = "Clear History…"
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .regular
        clearButton.target = self
        clearButton.action = #selector(clearAll)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        for view in [searchField, scrollView, emptyLabel, separator, clearButton] as [NSView] {
            container.addSubview(view)
        }

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),

            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -8),

            clearButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            clearButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        window.contentView = container
        window.initialFirstResponder = searchField
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open in New Tab", action: #selector(openSelection), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Link", action: #selector(copySelection), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(deleteSelection), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    // MARK: - Showing

    func show() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .historyDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.reloadPreservingSelection()
            }
        }
    }

    // MARK: - Data

    private func reload() {
        let query = searchField.stringValue
        rows = HistoryGrouping.rows(for: HistoryStore.shared.visits, query: query)
        tableView.reloadData()
        updateEmptyState(query: query)
        clearButton.isEnabled = !HistoryStore.shared.visits.isEmpty
    }

    /// A page finishing in a background tab posts `.historyDidChange`, which must not
    /// yank the selection out from under someone about to press Delete.
    private func reloadPreservingSelection() {
        let selected = Set(selectedVisits().map(\.id))
        reload()
        guard !selected.isEmpty else { return }
        let restored = IndexSet(rows.indices.filter { index in
            if case .visit(let visit) = rows[index] { return selected.contains(visit.id) }
            return false
        })
        tableView.selectRowIndexes(restored, byExtendingSelection: false)
    }

    private func updateEmptyState(query: String) {
        emptyLabel.isHidden = !rows.isEmpty
        guard rows.isEmpty else { return }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            emptyLabel.stringValue = "No history matching “\(query)”"
        } else if !SuggestionEngine.shared.isEnabled {
            // Recording is gated on the suggestions setting, so an empty window here
            // is a setting, not a bug. Say which one rather than showing a blank list.
            emptyLabel.stringValue = """
            History isn’t being recorded.
            Turn on Tools ▸ New Tab Suggestions ▸ Show Suggestions to start recording.
            """
        } else {
            emptyLabel.stringValue = "No history yet"
        }
    }

    private func visits(at indexes: IndexSet) -> [Visit] {
        indexes.compactMap { index in
            guard rows.indices.contains(index), case .visit(let visit) = rows[index] else { return nil }
            return visit
        }
    }

    private func selectedVisits() -> [Visit] {
        visits(at: tableView.selectedRowIndexes)
    }

    /// What a command acts on. Right-clicking a row outside the selection targets that
    /// row alone, the way Finder does — otherwise the menu would silently act on rows
    /// somewhere else in the list.
    private func targetVisits() -> [Visit] {
        let clicked = tableView.clickedRow
        if clicked >= 0, !tableView.selectedRowIndexes.contains(clicked) {
            return visits(at: IndexSet(integer: clicked))
        }
        return selectedVisits()
    }

    // MARK: - Actions

    @objc private func searchChanged() {
        reload()
    }

    @objc private func openSelection() {
        let urls = targetVisits().compactMap { URL(string: $0.url) }
        guard !urls.isEmpty else { return }
        for url in urls {
            if let front = AppDelegate.shared.frontNormalBrowserController {
                front.openInNewTab(url)
            } else {
                AppDelegate.shared.openNewWindow(url: url)
            }
        }
    }

    @objc private func copySelection() {
        let urls = targetVisits().map(\.url)
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
    }

    @objc private func deleteSelection() {
        let ids = Set(targetVisits().map(\.id))
        guard !ids.isEmpty else { return }
        // Keep the cursor where it was rather than dumping the user at the top.
        let anchor = tableView.selectedRowIndexes.first ?? 0
        guard HistoryStore.shared.remove(ids: ids) > 0 else { return }
        reload()
        let next = min(anchor, rows.count - 1)
        if next >= 0, case .visit = rows[next] {
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        }
        scheduleRetrain()
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = """
        This deletes every recorded visit. New tab suggestions are trained on this \
        history, so they will be rebuilt from scratch. Bookmarks and website logins \
        are not affected.
        """
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            HistoryStore.shared.clear()
            self?.reload()
            self?.scheduleRetrain()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    /// Deleted visits must stop feeding the suggestion model — but a training pass per
    /// deleted row would be absurd, so the passes coalesce into one.
    private func scheduleRetrain() {
        pendingRetrain?.cancel()
        let work = DispatchWorkItem {
            SuggestionEngine.shared.retrain(completion: nil)
        }
        pendingRetrain = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

// MARK: - Table data

extension HistoryWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 44 }
        if case .header = rows[row] { return 28 }
        return 44
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .header(let title):
            let identifier = NSUserInterfaceItemIdentifier("header")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryHeaderRowView
                ?? HistoryHeaderRowView()
            view.identifier = identifier
            view.configure(title: title)
            return view
        case .visit(let visit):
            let identifier = NSUserInterfaceItemIdentifier("visit")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryRowView
                ?? HistoryRowView()
            view.identifier = identifier
            view.configure(with: visit)
            return view
        }
    }

    /// Date headers are labels, not rows you can act on.
    func tableView(_ tableView: NSTableView,
                   selectionIndexesForProposedSelection proposedIndexes: IndexSet) -> IndexSet {
        proposedIndexes.filteredIndexSet { index in
            guard rows.indices.contains(index) else { return false }
            if case .header = rows[index] { return false }
            return true
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .header = rows[row] { return false }
        return true
    }
}

