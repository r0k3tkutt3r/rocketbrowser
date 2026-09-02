import Cocoa

/// Copies a password with the concealed-type marker clipboard managers honour, and
/// takes it back after a minute unless something else has replaced it since.
enum PasswordClipboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func copy(_ secret: SecureString) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = secret.withString { pasteboard.setString($0, forType: .string) }
        pasteboard.setString("", forType: concealed)
        // Captured per copy rather than held in a shared property: with one static,
        // copying a second password inside the minute made the first copy's timer
        // clear the second one early.
        let ours = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            // Only if nothing else has taken the pasteboard since — clearing someone
            // else's clipboard would be worse than leaving ours.
            if pasteboard.changeCount == ours { pasteboard.clearContents() }
        }
    }
}

final class PasswordsTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]
        if deleteKeys.contains(event.keyCode), !selectedRowIndexes.isEmpty {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
}

/// What the detail pane hands back on Save. `password == nil` means "unchanged", so
/// editing a note never requires the password to be decrypted into the form.
struct PasswordEdit {
    var host: String
    var url: String?
    var username: String
    var title: String?
    var password: String?
    var notes: String?
}

/// The right-hand pane: read, reveal, copy, edit or create one entry.
final class PasswordDetailView: NSView, NSTextFieldDelegate {

    var onSave: ((PasswordEdit) -> Void)?
    var onDelete: (() -> Void)?
    var onReveal: ((@escaping (SecureString) -> Void) -> Void)?
    var onCopy: (() -> Void)?
    var onOpen: ((URL) -> Void)?

    private(set) var entry: PasswordEntry?
    private(set) var isNew = false

    private let siteField = NSTextField()
    private let usernameField = NSTextField()
    private let secureField = NSSecureTextField()
    private let plainField = NSTextField()
    private let notesView = NSTextView()
    private let notesScroll = NSScrollView()
    private let otpLabel = NSTextField(labelWithString: "")
    private let revealButton = NSButton(title: "Reveal", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let openButton = NSButton(title: "Open Site", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private let placeholder = NSTextField(labelWithString: "Select a password")
    private let grid: NSGridView
    private var passwordEdited = false
    private var revealed = false
    private var hideTimer: Timer?

    override init(frame frameRect: NSRect) {
        let siteLabel = NSTextField(labelWithString: "Site")
        let userLabel = NSTextField(labelWithString: "Username")
        let passLabel = NSTextField(labelWithString: "Password")
        let notesLabel = NSTextField(labelWithString: "Notes")
        let otpTitle = NSTextField(labelWithString: "One-time code")
        let passwordRow = NSStackView()
        grid = NSGridView(views: [[siteLabel, siteField], [userLabel, usernameField],
                                  [passLabel, passwordRow], [notesLabel, notesScroll], [otpTitle, otpLabel]])
        super.init(frame: frameRect)

        for label in [siteLabel, userLabel, passLabel, notesLabel, otpTitle] {
            label.textColor = .secondaryLabelColor
            label.alignment = .right
        }
        siteField.placeholderString = "https://example.com"
        usernameField.placeholderString = "name@example.com"
        secureField.placeholderString = "Password"
        plainField.isHidden = true
        for field in [siteField, usernameField, secureField, plainField] { field.delegate = self }

        passwordRow.orientation = .horizontal
        passwordRow.spacing = 6
        passwordRow.addArrangedSubview(secureField)
        passwordRow.addArrangedSubview(plainField)
        passwordRow.addArrangedSubview(revealButton)
        passwordRow.addArrangedSubview(copyButton)
        secureField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        plainField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        notesView.isRichText = false
        notesView.font = .systemFont(ofSize: 12)
        notesView.textContainerInset = NSSize(width: 4, height: 4)
        notesScroll.documentView = notesView
        notesScroll.hasVerticalScroller = true
        notesScroll.borderType = .bezelBorder
        notesScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        otpLabel.textColor = .secondaryLabelColor
        otpLabel.lineBreakMode = .byTruncatingMiddle
        otpLabel.isSelectable = true

        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 96
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        let buttons = NSStackView(views: [openButton, deleteButton, NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)
        saveButton.keyEquivalent = "\r"

        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        revealButton.target = self; revealButton.action = #selector(revealTapped)
        copyButton.target = self; copyButton.action = #selector(copyTapped)
        openButton.target = self; openButton.action = #selector(openTapped)
        saveButton.target = self; saveButton.action = #selector(saveTapped)
        cancelButton.target = self; cancelButton.action = #selector(cancelTapped)
        deleteButton.target = self; deleteButton.action = #selector(deleteTapped)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// nil clears the pane. The password is never loaded into the form: the secure
    /// field starts empty and only a typed value counts as an edit.
    func show(_ entry: PasswordEntry?) {
        hideRevealed()
        self.entry = entry
        isNew = false
        passwordEdited = false
        let hasEntry = entry != nil
        grid.isHidden = !hasEntry
        placeholder.isHidden = hasEntry
        for button in [openButton, deleteButton, cancelButton, saveButton] { button.isHidden = !hasEntry }
        guard let entry else { return }
        siteField.stringValue = entry.url ?? "https://\(entry.host)"
        usernameField.stringValue = entry.username
        secureField.stringValue = ""
        secureField.placeholderString = "••••••••••••"
        notesView.string = ""
        otpLabel.stringValue = ""
        revealButton.isEnabled = true
        copyButton.isEnabled = true
        openButton.isEnabled = URL(string: siteField.stringValue) != nil
        deleteButton.isEnabled = true
        saveButton.isEnabled = false
    }

    /// Notes and OTP arrive later, from the same unlock that revealed the password.
    func showSecret(_ secret: PasswordSecret) {
        notesView.string = secret.notes ?? ""
        otpLabel.stringValue = secret.otpAuth ?? ""
    }

    func beginNew(host: String? = nil) {
        show(PasswordEntry(host: host ?? "", url: host.map { "https://\($0)" }, username: ""))
        isNew = true
        siteField.stringValue = host.map { "https://\($0)" } ?? ""
        secureField.placeholderString = "Password"
        revealButton.isEnabled = false
        copyButton.isEnabled = false
        deleteButton.isEnabled = false
        openButton.isEnabled = false
        window?.makeFirstResponder(siteField)
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === secureField || notification.object as? NSTextField === plainField {
            passwordEdited = true
        }
        saveButton.isEnabled = true
        openButton.isEnabled = URL(string: siteField.stringValue) != nil
    }

    func textDidChange(_ notification: Notification) {
        saveButton.isEnabled = true
    }

    @objc private func revealTapped() {
        if revealed { hideRevealed(); return }
        onReveal? { [weak self] secret in
            guard let self else { return }
            secret.withString { self.plainField.stringValue = $0 }
            self.secureField.isHidden = true
            self.plainField.isHidden = false
            self.revealed = true
            self.revealButton.title = "Hide"
            self.hideTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                self?.hideRevealed()
            }
        }
    }

    func hideRevealed() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard revealed else { return }
        if passwordEdited { secureField.stringValue = plainField.stringValue }
        plainField.stringValue = ""
        plainField.isHidden = true
        secureField.isHidden = false
        revealed = false
        revealButton.title = "Reveal"
    }

    @objc private func copyTapped() { onCopy?() }

    @objc private func openTapped() {
        if let url = URL(string: siteField.stringValue) { onOpen?(url) }
    }

    @objc private func cancelTapped() { show(isNew ? nil : entry) }

    @objc private func deleteTapped() { onDelete?() }

    @objc private func saveTapped() {
        var site = siteField.stringValue.trimmingCharacters(in: .whitespaces)
        if !site.isEmpty, !site.contains("://") { site = "https://" + site }
        guard let url = URL(string: site), let host = SiteMatcher.host(from: url) else {
            NSSound.beep()
            window?.makeFirstResponder(siteField)
            return
        }
        let typed = revealed ? plainField.stringValue : secureField.stringValue
        if isNew, typed.isEmpty {
            NSSound.beep()
            window?.makeFirstResponder(secureField)
            return
        }
        let notes = notesView.string
        onSave?(PasswordEdit(host: host, url: site,
                             username: usernameField.stringValue.trimmingCharacters(in: .whitespaces),
                             title: entry?.title,
                             password: passwordEdited || isNew ? typed : nil,
                             notes: notes.isEmpty ? nil : notes))
    }
}

/// The manager: search, the site/username table, and the detail pane. Lists straight
/// from the index — browsing never prompts; reveal, copy, save and delete do.
final class PasswordsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    static let shared = PasswordsWindowController()

    /// Set by `AppDelegate` at launch, so the manager needs to know nothing about
    /// windows or tabs. Mirrors `ContentBlocker.shared.applyToAllWebViews`.
    static var openURL: ((URL) -> Void)?

    private let tableView = PasswordsTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let detail = PasswordDetailView(frame: .zero)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton(title: "Add…", target: nil, action: nil)
    private let importButton = NSButton(title: "Import…", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private var filtered: [PasswordEntry] = []
    private var observer: NSObjectProtocol?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Passwords"
        window.minSize = NSSize(width: 640, height: 380)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(selecting id: UUID? = nil) {
        if !(window?.isVisible ?? false) {
            window?.center()
            window?.setFrameAutosaveName("RocketPasswordsWindow")
        }
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let id, let row = filtered.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        observer = observer ?? NotificationCenter.default.addObserver(
            forName: .passwordsDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        searchField.placeholderString = "Search sites and usernames"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        (searchField.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true

        for (title, identifier, width) in [("Site", "site", 200), ("Username", "username", 180), ("Last Used", "used", 90)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = CGFloat(width)
            column.minWidth = 60
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.doubleAction = #selector(openSelected)
        tableView.target = self
        tableView.onDelete = { [weak self] in self?.deleteSelected() }
        tableView.menu = contextMenu()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor

        addButton.target = self; addButton.action = #selector(addTapped)
        importButton.target = self; importButton.action = #selector(importTapped)
        exportButton.target = self; exportButton.action = #selector(exportTapped)
        let buttons = NSStackView(views: [addButton, importButton, exportButton, NSView()])
        buttons.orientation = .horizontal

        let left = NSView()
        for view in [searchField, scrollView, emptyLabel, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            left.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: left.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),
            buttons.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -10),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(detail)
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        split.setPosition(480, ofDividerAt: 0)

        detail.onSave = { [weak self] edit in self?.save(edit) }
        detail.onDelete = { [weak self] in self?.deleteSelected() }
        detail.onReveal = { [weak self] deliver in self?.reveal(deliver) }
        detail.onCopy = { [weak self] in self?.copySelected() }
        detail.onOpen = { [weak self] url in self?.open(url) }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Site in New Tab", action: #selector(openSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Username", action: #selector(copyUsername), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Password", action: #selector(copySelected), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(deleteSelected), keyEquivalent: "").target = self
        return menu
    }

    // MARK: Data

    private func reload() {
        let store = PasswordStore.shared
        let selected = filtered.indices.filter { tableView.selectedRowIndexes.contains($0) }.map { filtered[$0].id }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = store.entriesLoaded
            .filter { query.isEmpty || $0.host.contains(query) || $0.username.lowercased().contains(query)
                || ($0.title?.lowercased().contains(query) ?? false) }
            .sorted { (SiteMatcher.displayHost($0.host), $0.username.lowercased())
                    < (SiteMatcher.displayHost($1.host), $1.username.lowercased()) }
        tableView.reloadData()
        let restored = IndexSet(filtered.indices.filter { selected.contains(filtered[$0].id) })
        tableView.selectRowIndexes(restored, byExtendingSelection: false)

        if store.needsRestore {
            emptyLabel.stringValue = "This vault was created on another Mac. Use Tools → Passwords → Restore from Recovery Key…"
        } else if !store.isSetUp {
            emptyLabel.stringValue = "No passwords saved yet.\nAdd one, import a CSV, or sign in to a site and choose Save."
        } else if filtered.isEmpty {
            emptyLabel.stringValue = query.isEmpty ? "No passwords saved yet." : "No matches."
        }
        emptyLabel.isHidden = !filtered.isEmpty
        exportButton.isEnabled = store.isSetUp && !store.entriesLoaded.isEmpty
        if restored.isEmpty, !detail.isNew { detail.show(nil) }
    }

    @objc private func searchChanged() { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let entry = filtered[row]
        let identifier = column.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        switch identifier.rawValue {
        case "site": cell.textField?.stringValue = SiteMatcher.displayHost(entry.host)
        case "username": cell.textField?.stringValue = entry.username
        default:
            cell.textField?.stringValue = entry.lastUsed.map { Self.relative.localizedString(for: $0, relativeTo: Date()) } ?? "—"
            cell.textField?.textColor = .secondaryLabelColor
        }
        return cell
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    func tableViewSelectionDidChange(_ notification: Notification) {
        let rows = tableView.selectedRowIndexes
        detail.show(rows.count == 1 ? filtered[rows.first!] : nil)
    }

    private var selectedEntries: [PasswordEntry] {
        tableView.selectedRowIndexes.map { filtered[$0] }
    }

    // MARK: Actions

    @objc private func addTapped() {
        PasswordFlows.ensureSetUp(from: window) { [weak self] ready in
            guard ready, let self else { return }
            self.tableView.deselectAll(nil)
            self.detail.beginNew()
        }
    }

    @objc private func importTapped() { PasswordFlows.importCSV(from: window) }
    @objc private func exportTapped() { PasswordFlows.exportCSV(from: window) }

    @objc private func openSelected() {
        guard let entry = selectedEntries.first,
              let url = URL(string: entry.url ?? "https://\(entry.host)") else { return }
        open(url)
    }

    private func open(_ url: URL) {
        Self.openURL?(url)
    }

    @objc private func copyUsername() {
        guard let entry = selectedEntries.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.username, forType: .string)
    }

    @objc private func copySelected() {
        guard let entry = selectedEntries.first else { return }
        PasswordStore.shared.password(for: entry.id, reason: "copy your password for \(SiteMatcher.displayHost(entry.host))") { [weak self] result in
            switch result {
            case .failure(let error): PasswordFlows.present(error, in: self?.window)
            case .success(let secret): PasswordClipboard.copy(secret)
            }
        }
    }

    private func reveal(_ deliver: @escaping (SecureString) -> Void) {
        guard let entry = detail.entry, !detail.isNew else { return }
        PasswordStore.shared.withSecrets(reason: "reveal your password for \(SiteMatcher.displayHost(entry.host))", { secrets -> (SecureString, PasswordSecret)? in
            guard let secret = secrets[entry.id] else { return nil }
            return (SecureString(secret.password), secret)
        }, completion: { [weak self] result in
            switch result {
            case .failure(let error): PasswordFlows.present(error, in: self?.window)
            case .success(let pair):
                guard let (password, secret) = pair, self?.detail.entry?.id == entry.id else { return }
                self?.detail.showSecret(secret)
                deliver(password)
            }
        })
    }

    private func save(_ edit: PasswordEdit) {
        let store = PasswordStore.shared
        let reason = "save your password for \(SiteMatcher.displayHost(edit.host))"
        if detail.isNew {
            let entry = PasswordEntry(host: edit.host, url: edit.url, username: edit.username, title: edit.title)
            store.add(entry, secret: PasswordSecret(password: edit.password ?? "", notes: edit.notes, otpAuth: nil),
                      reason: reason) { [weak self] result in
                switch result {
                case .failure(let error): PasswordFlows.present(error, in: self?.window)
                case .success: self?.show(selecting: entry.id)
                }
            }
            return
        }
        guard let existing = detail.entry else { return }
        store.mutate(reason: reason, { index, secrets in
            guard let position = index.entries.firstIndex(where: { $0.id == existing.id }),
                  var secret = secrets[existing.id] else { throw VaultError.corrupt }
            index.entries[position].host = edit.host
            index.entries[position].url = edit.url
            index.entries[position].username = edit.username
            index.entries[position].modified = Date()
            if let password = edit.password, !password.isEmpty { secret.password = password }
            secret.notes = edit.notes
            secrets[existing.id] = secret
        }, completion: { [weak self] result in
            switch result {
            case .failure(let error): PasswordFlows.present(error, in: self?.window)
            case .success: self?.show(selecting: existing.id)
            }
        })
    }

    @objc private func deleteSelected() {
        let entries = selectedEntries
        guard !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = entries.count == 1
            ? "Delete the password for \(entries[0].username) at \(SiteMatcher.displayHost(entries[0].host))?"
            : "Delete \(entries.count) passwords?"
        alert.informativeText = "This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        PasswordFlows.run(alert, in: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            PasswordStore.shared.delete(ids: Set(entries.map(\.id)), reason: "delete saved passwords") { result in
                if case .failure(let error) = result { PasswordFlows.present(error, in: self?.window) }
            }
        }
    }
}

extension PasswordsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        detail.hideRevealed()
        detail.show(nil)
        tableView.deselectAll(nil)
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}
