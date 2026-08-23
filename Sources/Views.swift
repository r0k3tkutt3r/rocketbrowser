import Cocoa

/// Address bar text field that selects its contents when focused (Safari-style).
final class URLField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in
                self?.currentEditor()?.selectAll(nil)
            }
        }
        return accepted
    }
}

/// Thin accent-colored page-load progress bar shown along the top of the web view.
final class ProgressBar: NSView {

    private let fill = NSView()

    var progress: Double = 0 {
        didSet { layoutFill(animated: progress > oldValue) }
    }

    var isLoading = false {
        didSet {
            guard isLoading != oldValue else { return }
            if isLoading {
                alphaValue = 1
            } else {
                progress = 1
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.4
                    self.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    self?.progress = 0
                })
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        addSubview(fill)
        alphaValue = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        layoutFill(animated: false)
    }

    private func layoutFill(animated: Bool) {
        let target = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(progress), height: bounds.height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                fill.animator().frame = target
            }
        } else {
            fill.frame = target
        }
    }
}

extension NSPasteboard.PasteboardType {
    static let rocketBookmark = NSPasteboard.PasteboardType("com.kushmodi.rocket.bookmark")
}

/// A bookmark bar button that remembers which bookmark (or folder) it represents.
/// Bookmark buttons can be dragged; folder buttons accept dropped bookmarks.
final class BookmarkButton: NSButton, NSDraggingSource {

    var bookmark: Bookmark? {
        didSet {
            if bookmark?.isFolder == true {
                registerForDraggedTypes([.rocketBookmark])
            } else {
                unregisterDraggedTypes()
            }
        }
    }

    // MARK: - Drag source (bookmarks only)

    override func mouseDown(with event: NSEvent) {
        guard let bookmark, !bookmark.isFolder else {
            super.mouseDown(with: event)
            return
        }
        // Track manually: a small movement starts a drag, a plain release is a click.
        let start = event.locationInWindow
        var didDrag = false
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp { break }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 4 {
                didDrag = true
                beginDrag(with: next, bookmark: bookmark)
                break
            }
        }
        if !didDrag {
            performClick(nil)
        }
    }

    private func beginDrag(with event: NSEvent, bookmark: Bookmark) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(bookmark.id.uuidString, forType: .rocketBookmark)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let snapshot = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            snapshot.addRepresentation(rep)
        }
        draggingItem.setDraggingFrame(bounds, contents: snapshot)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    // MARK: - Drop target (folders only)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard bookmark?.isFolder == true, draggedBookmarkID(sender) != nil else { return [] }
        isHighlighted = true
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        guard let folder = bookmark, folder.isFolder,
              let id = draggedBookmarkID(sender) else { return false }
        // Mutate after the drag session unwinds — the store change rebuilds the bar.
        DispatchQueue.main.async {
            BookmarkStore.shared.moveBookmark(id: id, intoFolderID: folder.id)
        }
        return true
    }

    private func draggedBookmarkID(_ info: NSDraggingInfo) -> UUID? {
        info.draggingPasteboard.string(forType: .rocketBookmark).flatMap(UUID.init(uuidString:))
    }
}

/// Horizontal bookmarks bar shown under the toolbar. Scrollable when it overflows,
/// rebuilds itself whenever the bookmark store changes. Folders show a dropdown of
/// their bookmarks on click; right-click anywhere for add/edit/delete management.
final class BookmarksBarView: NSVisualEffectView, NSMenuItemValidation {

    /// Opens a leaf bookmark (second argument: open in a new tab).
    var onOpen: ((Bookmark, _ inNewTab: Bool) -> Void)?
    /// Supplies the front tab's page for "Add Current Page"; nil on internal pages.
    var currentPage: (() -> (title: String, url: String)?)?

    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private let placeholder = NSTextField(labelWithString: "Pages you bookmark with ⌘D appear here — right-click to add pages and folders")
    private var observer: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        placeholder.font = .systemFont(ofSize: 11)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        menu = backgroundMenu()
        registerForDraggedTypes([.rocketBookmark])
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: .bookmarksDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    // Dropping a bookmark on the bar background moves it back to the top level.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.string(forType: .rocketBookmark) != nil ? .move : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = sender.draggingPasteboard.string(forType: .rocketBookmark)
            .flatMap(UUID.init(uuidString:)) else { return false }
        DispatchQueue.main.async {
            BookmarkStore.shared.moveBookmark(id: id, intoFolderID: nil)
        }
        return true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Building

    private func reload() {
        for view in stack.arrangedSubviews {
            view.removeFromSuperview()
        }
        let items = BookmarkStore.shared.items
        placeholder.isHidden = !items.isEmpty
        for item in items {
            let button = BookmarkButton(title: item.title, target: self, action: #selector(buttonClicked(_:)))
            button.bookmark = item
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11.5)
            button.lineBreakMode = .byTruncatingTail
            if item.isFolder {
                button.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
                button.imagePosition = .imageLeading
                button.toolTip = "\(item.children?.count ?? 0) bookmarks"
            } else {
                button.toolTip = item.url
            }
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
            button.menu = contextMenu(for: item)
            stack.addArrangedSubview(button)
        }
    }

    // MARK: - Context menus

    private func backgroundMenu() -> NSMenu {
        let menu = NSMenu()
        appendManagementItems(to: menu)
        return menu
    }

    private func appendManagementItems(to menu: NSMenu) {
        let addCurrent = menu.addItem(withTitle: "Add Current Page",
                                      action: #selector(addCurrentPage(_:)), keyEquivalent: "")
        addCurrent.target = self
        let addManual = menu.addItem(withTitle: "Add Page…",
                                     action: #selector(addPage(_:)), keyEquivalent: "")
        addManual.target = self
        let newFolder = menu.addItem(withTitle: "New Folder…",
                                     action: #selector(newFolder(_:)), keyEquivalent: "")
        newFolder.target = self
    }

    private func contextMenu(for item: Bookmark) -> NSMenu {
        let menu = NSMenu()
        if item.isFolder {
            let addHere = menu.addItem(withTitle: "Add Current Page to “\(item.title)”",
                                       action: #selector(addCurrentPage(_:)), keyEquivalent: "")
            addHere.target = self
            addHere.representedObject = item
            let addPageHere = menu.addItem(withTitle: "Add Page to “\(item.title)”…",
                                           action: #selector(addPage(_:)), keyEquivalent: "")
            addPageHere.target = self
            addPageHere.representedObject = item
            menu.addItem(.separator())
            let rename = menu.addItem(withTitle: "Rename Folder…",
                                      action: #selector(editItem(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = item
            let delete = menu.addItem(withTitle: "Delete Folder",
                                      action: #selector(deleteItem(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = item
        } else {
            let openTab = menu.addItem(withTitle: "Open in New Tab",
                                       action: #selector(openInNewTab(_:)), keyEquivalent: "")
            openTab.target = self
            openTab.representedObject = item
            menu.addItem(.separator())
            let edit = menu.addItem(withTitle: "Edit…",
                                    action: #selector(editItem(_:)), keyEquivalent: "")
            edit.target = self
            edit.representedObject = item
            let delete = menu.addItem(withTitle: "Delete",
                                      action: #selector(deleteItem(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = item
        }
        menu.addItem(.separator())
        appendManagementItems(to: menu)
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(addCurrentPage(_:)) {
            return currentPage?() != nil
        }
        return true
    }

    // MARK: - Folder dropdown

    private func showFolderMenu(for button: BookmarkButton, folder: Bookmark) {
        let menu = NSMenu()
        let children = (folder.children ?? []).filter { !$0.isFolder }
        if children.isEmpty {
            let empty = menu.addItem(withTitle: "Empty Folder", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
        for child in children {
            let item = menu.addItem(withTitle: child.title,
                                    action: #selector(openFolderChild(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = child
            item.toolTip = child.url
        }
        menu.addItem(.separator())
        let addCurrent = menu.addItem(withTitle: "Add Current Page",
                                      action: #selector(addCurrentPage(_:)), keyEquivalent: "")
        addCurrent.target = self
        addCurrent.representedObject = folder
        let addManual = menu.addItem(withTitle: "Add Page…",
                                     action: #selector(addPage(_:)), keyEquivalent: "")
        addManual.target = self
        addManual.representedObject = folder
        if !children.isEmpty {
            menu.addItem(.separator())
            let editMenu = NSMenu()
            let deleteMenu = NSMenu()
            for child in children {
                let edit = editMenu.addItem(withTitle: child.title,
                                            action: #selector(editItem(_:)), keyEquivalent: "")
                edit.target = self
                edit.representedObject = child
                let delete = deleteMenu.addItem(withTitle: child.title,
                                                action: #selector(deleteItem(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = child
            }
            let editParent = menu.addItem(withTitle: "Edit Bookmark", action: nil, keyEquivalent: "")
            menu.setSubmenu(editMenu, for: editParent)
            let deleteParent = menu.addItem(withTitle: "Delete Bookmark", action: nil, keyEquivalent: "")
            menu.setSubmenu(deleteMenu, for: deleteParent)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
    }

    // MARK: - Actions

    @objc private func buttonClicked(_ sender: BookmarkButton) {
        guard let item = sender.bookmark else { return }
        if item.isFolder {
            showFolderMenu(for: sender, folder: item)
        } else {
            let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            onOpen?(item, commandHeld)
        }
    }

    @objc private func openFolderChild(_ sender: NSMenuItem) {
        guard let child = sender.representedObject as? Bookmark else { return }
        let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        onOpen?(child, commandHeld)
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? Bookmark else { return }
        onOpen?(item, true)
    }

    @objc private func addCurrentPage(_ sender: NSMenuItem) {
        guard let page = currentPage?() else { return }
        let folder = sender.representedObject as? Bookmark
        BookmarkStore.shared.addBookmark(Bookmark(title: page.title, url: page.url),
                                         toFolderID: folder?.id)
    }

    @objc private func addPage(_ sender: NSMenuItem) {
        let folder = sender.representedObject as? Bookmark
        let page = currentPage?()
        let dialogTitle = folder.map { "Add Page to “\($0.title)”" } ?? "Add Page"
        guard let result = promptForPage(dialogTitle: dialogTitle,
                                         initialTitle: page?.title ?? "",
                                         initialURL: page?.url ?? "") else { return }
        BookmarkStore.shared.addBookmark(Bookmark(title: result.title, url: result.url),
                                         toFolderID: folder?.id)
    }

    @objc private func newFolder(_ sender: NSMenuItem) {
        guard let name = promptForText(dialogTitle: "New Folder",
                                       placeholder: "Folder name", initial: "") else { return }
        BookmarkStore.shared.addFolder(named: name)
    }

    @objc private func editItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? Bookmark else { return }
        if item.isFolder {
            guard let name = promptForText(dialogTitle: "Rename Folder",
                                           placeholder: "Folder name", initial: item.title) else { return }
            BookmarkStore.shared.update(id: item.id, title: name, url: nil)
        } else {
            guard let result = promptForPage(dialogTitle: "Edit Bookmark",
                                             initialTitle: item.title,
                                             initialURL: item.url ?? "") else { return }
            BookmarkStore.shared.update(id: item.id, title: result.title, url: result.url)
        }
    }

    @objc private func deleteItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? Bookmark else { return }
        BookmarkStore.shared.removeItem(id: item.id)
    }

    // MARK: - Dialogs

    private func promptForPage(dialogTitle: String,
                               initialTitle: String,
                               initialURL: String) -> (title: String, url: String)? {
        let alert = NSAlert()
        alert.messageText = dialogTitle
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let titleField = NSTextField(frame: NSRect(x: 0, y: 32, width: 280, height: 24))
        titleField.placeholderString = "Title"
        titleField.stringValue = initialTitle
        let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        urlField.placeholderString = "https://example.com"
        urlField.stringValue = initialURL
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
        container.addSubview(titleField)
        container.addSubview(urlField)
        alert.accessoryView = container
        alert.window.initialFirstResponder = titleField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let rawURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else { return nil }
        let url = URLResolver.resolve(rawURL)?.absoluteString ?? rawURL
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? url : title, url)
    }

    private func promptForText(dialogTitle: String, placeholder: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = dialogTitle
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Turns address-bar input into a URL: direct URLs load as-is, bare hosts get https://,
/// everything else becomes a search query.
enum URLResolver {
    static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

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

        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }
}

func htmlEscaped(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
