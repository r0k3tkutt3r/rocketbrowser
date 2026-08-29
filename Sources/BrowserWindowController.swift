import Cocoa
import WebKit

/// One browser tab. Tabs are native macOS window tabs (Safari-style): each tab is a
/// window managed by one of these controllers, grouped by tabbingIdentifier.
final class BrowserWindowController: NSWindowController {

    let webView: WKWebView
    /// Non-nil marks this tab as incognito; the session owns the ephemeral data store
    /// shared by every tab spawned from the same incognito window.
    let incognitoSession: IncognitoSession?
    var isPrivate: Bool { incognitoSession != nil }

    private let urlField = URLField()
    private let progressBar = ProgressBar(frame: .zero)
    private let bookmarksBar = BookmarksBarView()
    private var bookmarksBarHeight: NSLayoutConstraint!
    private var reloadToolbarItem: NSToolbarItem?
    private var bookmarkToolbarItem: NSToolbarItem?
    private var observations: [NSKeyValueObservation] = []
    private var bookmarkObserver: NSObjectProtocol?
    private var downloads = Set<WKDownload>()
    private var suppressHistoryOnce = false

    private let suggestionsDropdown = SuggestionsDropdown()
    private var remoteSuggestionTask: URLSessionDataTask?
    private var suggestionDebounce: DispatchWorkItem?
    private var downloadsToolbarItem: NSToolbarItem?
    private weak var downloadsButton: NSButton?
    private let downloadsPopover = NSPopover()
    private var downloadsObserver: NSObjectProtocol?
    /// Open history visit for the page on screen, closed when the tab navigates away.
    private var currentVisitID: UUID?
    /// Set when the pending navigation was NOT started by the user (a redirect).
    private var pendingNavigationViaRedirect = false
    private var nextNavigationIsUserInitiated = false
    /// What the user actually typed, kept while arrow keys preview suggestions.
    private var typedTextBeforeSelection: String?
    /// Attention accounting for the page on screen: seconds accumulated while this tab
    /// was front-most and Rocket was the active app, plus the open interval's start.
    private var activeAccumulated: TimeInterval = 0
    private var activeSince: Date?
    private var focusObservers: [NSObjectProtocol] = []

    private enum ItemID {
        static let back = NSToolbarItem.Identifier("rocket.back")
        static let forward = NSToolbarItem.Identifier("rocket.forward")
        static let urlField = NSToolbarItem.Identifier("rocket.urlField")
        static let reload = NSToolbarItem.Identifier("rocket.reload")
        static let bookmark = NSToolbarItem.Identifier("rocket.bookmark")
        static let downloads = NSToolbarItem.Identifier("rocket.downloads")
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Match Safari's user agent exactly; some sites (notably Google sign-in)
        // degrade or block the bare WKWebView agent.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }

    init(configuration: WKWebViewConfiguration = BrowserWindowController.makeConfiguration(),
         incognitoSession: IncognitoSession? = nil) {
        // WebKit maps the Delete key to "go back" by default in WKWebView; Safari
        // disables that via this WebKit preference. Applied to every configuration,
        // including ones WebKit hands us for popups. Backspace still works in forms.
        let preferences = configuration.preferences
        if preferences.responds(to: NSSelectorFromString("_setBackspaceKeyNavigationEnabled:")) {
            preferences.setValue(false, forKey: "backspaceKeyNavigationEnabled")
        }
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.incognitoSession = incognitoSession
        incognitoSession?.attach()
        let isPrivate = incognitoSession != nil

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        super.init(window: window)

        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.title = isPrivate ? "Incognito" : "New Tab"
        window.tabbingIdentifier = isPrivate ? "rocket.private" : "rocket.browser"
        // Incognito is always dark, regardless of the system appearance. This also
        // flips the web view's prefers-color-scheme to dark for sites.
        if isPrivate { window.appearance = NSAppearance(named: .darkAqua) }
        window.toolbarStyle = .unified
        window.delegate = self
        if !window.setFrameUsingName("RocketBrowserWindow") { window.center() }
        window.setFrameAutosaveName("RocketBrowserWindow")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true

        ContentBlocker.shared.apply(to: webView, isIncognito: isPrivate)

        let content = NSView()
        bookmarksBar.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bookmarksBar)
        content.addSubview(webView)
        content.addSubview(progressBar)
        bookmarksBarHeight = bookmarksBar.heightAnchor.constraint(equalToConstant: 30)
        NSLayoutConstraint.activate([
            bookmarksBar.topAnchor.constraint(equalTo: content.topAnchor),
            bookmarksBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bookmarksBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bookmarksBarHeight,
            webView.topAnchor.constraint(equalTo: bookmarksBar.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: webView.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 3),
        ])
        window.contentView = content

        bookmarksBar.onOpen = { [weak self] bookmark, inNewTab in
            guard let self, let urlString = bookmark.url, let url = URL(string: urlString) else { return }
            if inNewTab {
                self.openInNewTab(url)
            } else {
                self.load(url)
            }
        }
        bookmarksBar.currentPage = { [weak self] in
            guard let self,
                  let urlString = self.webView.url?.absoluteString,
                  !urlString.isEmpty, urlString != "about:blank",
                  !NewTabPage.isNewTabURL(self.webView.url) else { return nil }
            let title = self.webView.title ?? ""
            return (title.isEmpty ? urlString : title, urlString)
        }
        updateBookmarksBarVisibility()

        bookmarkObserver = NotificationCenter.default.addObserver(
            forName: .bookmarksDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateBookmarkItem()
        }

        // The new tab page's retrain button posts here. Remove first: popups share the
        // opener's userContentController, and adding a duplicate name throws.
        let userContent = webView.configuration.userContentController
        userContent.removeScriptMessageHandler(forName: "rocket")
        userContent.add(self, name: "rocket")

        // Attention is only counted while Rocket itself is frontmost.
        let center = NotificationCenter.default
        focusObservers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.resumeActiveTiming()
            },
            center.addObserver(forName: NSApplication.willResignActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.pauseActiveTiming()
            },
        ]

        configureURLField()
        configureToolbar()
        startObservations()
    }

    // MARK: - Attention timing

    private var isFrontmostTab: Bool {
        NSApp.isActive && (window?.isKeyWindow ?? false)
    }

    private func resumeActiveTiming() {
        guard activeSince == nil, isFrontmostTab else { return }
        activeSince = Date()
    }

    private func pauseActiveTiming() {
        guard let since = activeSince else { return }
        activeAccumulated += Date().timeIntervalSince(since)
        activeSince = nil
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Setup

    private func configureURLField() {
        urlField.placeholderString = "Search or enter website address"
        urlField.bezelStyle = .roundedBezel
        urlField.font = .systemFont(ofSize: 13)
        urlField.usesSingleLineMode = true
        urlField.lineBreakMode = .byTruncatingTail
        urlField.cell?.sendsActionOnEndEditing = false
        urlField.delegate = self
        urlField.target = self
        urlField.action = #selector(urlFieldSubmitted(_:))

        // Editing always works against the real URL, never the shortened display form.
        urlField.onFocus = { [weak self] in
            guard let self, let url = self.webView.url, !NewTabPage.isNewTabURL(url) else { return }
            self.urlField.stringValue = url.absoluteString
        }
        suggestionsDropdown.onAccept = { [weak self] suggestion in
            guard let self else { return }
            self.urlField.stringValue = suggestion.url.absoluteString
            self.load(suggestion.url)
            self.window?.makeFirstResponder(self.webView)
        }

        downloadsPopover.behavior = .transient
        downloadsPopover.contentViewController = DownloadsViewController()
        downloadsObserver = NotificationCenter.default.addObserver(
            forName: .downloadsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateDownloadsItem()
        }
    }

    // MARK: - Downloads

    @objc func showDownloads(_ sender: Any?) {
        // Fall back to the window's content view if the toolbar item is off-screen
        // (overflow menu, very narrow window) so the list is always reachable.
        let anchor: NSView? = downloadsButton ?? window?.contentView
        guard let anchor else { return }
        if downloadsPopover.isShown {
            downloadsPopover.performClose(nil)
            return
        }
        let rect = anchor === downloadsButton
            ? anchor.bounds
            : NSRect(x: anchor.bounds.maxX - 40, y: anchor.bounds.maxY - 1, width: 32, height: 1)
        downloadsPopover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
    }

    /// Pops the list open the first time a download starts, the way Safari does.
    private func showDownloadsPopoverIfHidden() {
        guard !downloadsPopover.isShown, window?.isKeyWindow == true else { return }
        showDownloads(nil)
    }

    private func updateDownloadsItem() {
        let active = DownloadsManager.shared.hasActiveDownloads
        downloadsButton?.image = NSImage(
            systemSymbolName: active ? "arrow.down.circle.fill" : "arrow.down.circle",
            accessibilityDescription: "Downloads")
    }

    // MARK: - Address bar suggestions

    private func refreshSuggestions() {
        suggestionDebounce?.cancel()
        remoteSuggestionTask?.cancel()

        let text = urlField.stringValue
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            suggestionsDropdown.hide()
            return
        }

        var results = AddressSuggestionProvider.local(for: text)
        // The literal typed text always leads, so Return does what it looks like.
        if let direct = URLResolver.resolve(text, privateSearch: isPrivate) {
            let isSearch = URLDisplay.searchQuery(from: direct) != nil
            results.insert(AddressSuggestion(kind: isSearch ? .search : .history,
                                             title: text,
                                             subtitle: isSearch ? "Search" : "Open",
                                             url: direct), at: 0)
        }
        suggestionsDropdown.show(results, below: urlField)

        // Remote completions land a beat later and are appended without disturbing
        // whatever the user has already selected with the arrow keys.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.remoteSuggestionTask = AddressSuggestionProvider.remote(
                for: text, privateSearch: self.isPrivate
            ) { [weak self] completions in
                guard let self, self.urlField.stringValue == text else { return }
                var merged = results
                for completion in completions.prefix(5) {
                    guard !merged.contains(where: { $0.title.caseInsensitiveCompare(completion) == .orderedSame }),
                          let url = URLResolver.resolve(completion, privateSearch: self.isPrivate) else { continue }
                    merged.append(AddressSuggestion(kind: .search, title: completion,
                                                    subtitle: nil, url: url))
                }
                if self.window?.firstResponder === self.urlField.currentEditor() {
                    self.suggestionsDropdown.show(merged, below: self.urlField)
                }
            }
        }
        suggestionDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "RocketToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [ItemID.urlField]
        window?.toolbar = toolbar
    }

    private func startObservations() {
        observations = [
            webView.observe(\.url) { [weak self] _, _ in
                self?.syncURLField()
                self?.updateBookmarkItem()
            },
            webView.observe(\.title) { [weak self] _, _ in
                self?.updateWindowTitle()
            },
            webView.observe(\.estimatedProgress) { [weak self] webView, _ in
                self?.progressBar.progress = webView.estimatedProgress
            },
            webView.observe(\.isLoading) { [weak self] webView, _ in
                self?.progressBar.isLoading = webView.isLoading
                self?.updateReloadItem()
                self?.window?.toolbar?.validateVisibleItems()
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in
                self?.window?.toolbar?.validateVisibleItems()
            },
            webView.observe(\.canGoForward) { [weak self] _, _ in
                self?.window?.toolbar?.validateVisibleItems()
            },
        ]
    }

    // MARK: - State updates

    private func updateWindowTitle() {
        let pageTitle = webView.title ?? ""
        let fallback = webView.url?.host ?? "New Tab"
        let title = pageTitle.isEmpty ? fallback : pageTitle
        window?.title = (isPrivate ? "🕶 " : "") + title
    }

    private func syncURLField(force: Bool = false) {
        if !force, let editor = urlField.currentEditor(), window?.firstResponder === editor {
            return
        }
        // Unfocused, the field shows the simplified form ("google.com — hello").
        // Focusing it swaps in the real URL so editing and copying are unaffected.
        urlField.stringValue = NewTabPage.isNewTabURL(webView.url)
            ? "" : URLDisplay.displayString(for: webView.url)
    }

    func updateBookmarksBarVisibility() {
        let show = UserDefaults.standard.object(forKey: "ShowBookmarksBar") as? Bool ?? true
        bookmarksBar.isHidden = !show
        bookmarksBarHeight.constant = show ? 30 : 0
    }

    private func updateReloadItem() {
        let symbol = webView.isLoading ? "xmark" : "arrow.clockwise"
        let label = webView.isLoading ? "Stop" : "Reload"
        reloadToolbarItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        reloadToolbarItem?.label = label
        reloadToolbarItem?.toolTip = label
    }

    private func updateBookmarkItem() {
        let bookmarked = webView.url.map { BookmarkStore.shared.containsBookmark(url: $0.absoluteString) } ?? false
        bookmarkToolbarItem?.image = NSImage(
            systemSymbolName: bookmarked ? "star.fill" : "star",
            accessibilityDescription: "Bookmark")
    }

    // MARK: - Loading

    func load(_ url: URL) {
        // Marks this navigation as deliberate, so the history recorder does not
        // mistake a typed URL or a bookmark for a redirect hop.
        nextNavigationIsUserInitiated = true
        webView.load(URLRequest(url: url))
    }

    @discardableResult
    func openInNewTab(_ url: URL?) -> BrowserWindowController {
        let configuration = webView.configuration.copy() as! WKWebViewConfiguration
        let controller = BrowserWindowController(configuration: configuration, incognitoSession: incognitoSession)
        AppDelegate.shared.register(controller)
        attachAsTab(controller)
        if let url {
            controller.load(url)
        } else {
            controller.openNewTabPage()
        }
        return controller
    }

    func openNewTabPage() {
        if isPrivate {
            // The normal start page is a shared on-disk file rendering suggestion
            // chips learned from normal-browsing history — neither belongs here.
            NewTabPage.openIncognito(in: webView)
        } else {
            NewTabPage.open(in: webView)
        }
        focusAddressBar(nil)
    }

    private func attachAsTab(_ controller: BrowserWindowController) {
        if let hostWindow = window, let newWindow = controller.window {
            hostWindow.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
        }
    }

    // MARK: - Actions

    @objc func navigateBack(_ sender: Any?) {
        webView.goBack()
    }

    @objc func navigateForward(_ sender: Any?) {
        webView.goForward()
    }

    @objc func reloadPage(_ sender: Any?) {
        webView.reload()
    }

    @objc func stopLoadingPage(_ sender: Any?) {
        webView.stopLoading()
    }

    @objc func reloadOrStop(_ sender: Any?) {
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    @objc func focusAddressBar(_ sender: Any?) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(urlField)
    }

    @objc func goHome(_ sender: Any?) {
        load(AppDelegate.homepage)
    }

    @objc func pageZoomIn(_ sender: Any?) {
        webView.pageZoom = min(webView.pageZoom + 0.1, 3.0)
        resetMagnification()
    }

    @objc func pageZoomOut(_ sender: Any?) {
        webView.pageZoom = max(webView.pageZoom - 0.1, 0.5)
        resetMagnification()
    }

    @objc func pageZoomActual(_ sender: Any?) {
        webView.pageZoom = 1.0
        resetMagnification()
    }

    /// `magnification` (trackpad pinch) is a separate property from `pageZoom`, and a
    /// stray pinch otherwise sticks forever: the whole rendered surface stays larger
    /// than the viewport, so the page pans in both directions and even position:fixed
    /// chrome like a sidebar drifts. Keyboard zoom is authoritative, so it clears it.
    private func resetMagnification() {
        if webView.magnification != 1.0 {
            webView.setMagnification(1.0, centeredAt: .zero)
        }
    }

    override func newWindowForTab(_ sender: Any?) {
        openInNewTab(nil)
    }

    /// ⌘1–⌘9: switch to the Nth tab in this window's tab group (⌘9 clamps to the last).
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard let group = window?.tabGroup, !group.windows.isEmpty else { return }
        let index = min(sender.tag, group.windows.count) - 1
        guard index >= 0 else { return }
        group.selectedWindow = group.windows[index]
    }

    @objc func openFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    @objc func toggleBookmark(_ sender: Any?) {
        guard let urlString = webView.url?.absoluteString,
              !urlString.isEmpty, urlString != "about:blank",
              !NewTabPage.isNewTabURL(webView.url) else { return }
        let store = BookmarkStore.shared
        if store.containsBookmark(url: urlString) {
            store.removeBookmark(url: urlString)
        } else {
            let pageTitle = webView.title ?? ""
            store.addBookmark(Bookmark(title: pageTitle.isEmpty ? urlString : pageTitle, url: urlString))
        }
        updateBookmarkItem()
    }

    @objc private func urlFieldSubmitted(_ sender: Any?) {
        guard let url = URLResolver.resolve(urlField.stringValue, privateSearch: isPrivate) else { return }
        load(url)
        window?.makeFirstResponder(webView)
    }

    // MARK: - Error page

    private func showErrorPage(_ error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        // 102: frame load interrupted (e.g. a navigation became a download); 204: plugin handled.
        if nsError.domain == "WebKitErrorDomain", [102, 204].contains(nsError.code) { return }

        let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        suppressHistoryOnce = true
        let html = """
        <!doctype html>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
            body { font-family: -apple-system, sans-serif; display: flex; align-items: center;
                   justify-content: center; height: 90vh; }
            main { text-align: center; max-width: 34em; opacity: 0.75; }
            h1 { font-size: 1.3em; }
            .url { word-break: break-all; font-size: 0.85em; }
        </style>
        <main>
            <h1>Rocket can’t open this page</h1>
            <p>\(htmlEscaped(nsError.localizedDescription))</p>
            <p class="url">\(htmlEscaped(failingURL?.absoluteString ?? ""))</p>
        </main>
        """
        webView.loadHTMLString(html, baseURL: failingURL)
    }
}

// MARK: - NSWindowDelegate

extension BrowserWindowController: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        resumeActiveTiming()
    }

    func windowDidResignKey(_ notification: Notification) {
        pauseActiveTiming()
    }

    func windowWillClose(_ notification: Notification) {
        // Stamp the dwell time for the page on screen, then offer the tab to ⇧⌘T.
        pauseActiveTiming()
        closeCurrentVisit()
        // Breaks the retain cycle: the content controller holds its message handlers.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rocket")
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers.removeAll()
        suggestionsDropdown.hide()
        if !isPrivate, let url = webView.url, !NewTabPage.isNewTabURL(url) {
            AppDelegate.shared.recordClosedTab(url: url, title: webView.title)
        }
        if let downloadsObserver {
            NotificationCenter.default.removeObserver(downloadsObserver)
            self.downloadsObserver = nil
        }
        observations.removeAll()
        if let bookmarkObserver {
            NotificationCenter.default.removeObserver(bookmarkObserver)
            self.bookmarkObserver = nil
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        // Last window out destroys the session's data store — the on-disk files
        // are deleted as soon as the web view releases them.
        incognitoSession?.detach()
        AppDelegate.shared.unregister(self)
    }
}

// MARK: - Toolbar

extension BrowserWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.back, ItemID.forward, .flexibleSpace,
         ItemID.urlField, .flexibleSpace, ItemID.reload, ItemID.bookmark, ItemID.downloads]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemID.back:
            let item = makeButton(itemIdentifier, symbol: "chevron.backward", label: "Back",
                                  action: #selector(navigateBack(_:)))
            item.isNavigational = true
            return item
        case ItemID.forward:
            let item = makeButton(itemIdentifier, symbol: "chevron.forward", label: "Forward",
                                  action: #selector(navigateForward(_:)))
            item.isNavigational = true
            return item
        case ItemID.reload:
            let item = makeButton(itemIdentifier, symbol: "arrow.clockwise", label: "Reload",
                                  action: #selector(reloadOrStop(_:)))
            reloadToolbarItem = item
            return item
        case ItemID.bookmark:
            let item = makeButton(itemIdentifier, symbol: "star", label: "Bookmark",
                                  action: #selector(toggleBookmark(_:)))
            bookmarkToolbarItem = item
            return item
        case ItemID.downloads:
            // A custom view (not a plain image item) so the popover always has a
            // concrete anchor to attach to.
            let button = NSButton(image: NSImage(systemSymbolName: "arrow.down.circle",
                                                 accessibilityDescription: "Downloads")!,
                                  target: self, action: #selector(showDownloads(_:)))
            button.bezelStyle = .texturedRounded
            button.setButtonType(.momentaryPushIn)
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = "Downloads"
            item.toolTip = "Downloads"
            downloadsButton = button
            downloadsToolbarItem = item
            return item
        case ItemID.urlField:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Address"
            item.view = urlField
            urlField.translatesAutoresizingMaskIntoConstraints = false
            urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            let preferred = urlField.widthAnchor.constraint(equalToConstant: 660)
            preferred.priority = .defaultLow
            preferred.isActive = true
            return item
        default:
            return nil
        }
    }

    private func makeButton(_ identifier: NSToolbarItem.Identifier,
                            symbol: String, label: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }
}

// MARK: - Validation

extension BrowserWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case ItemID.back: return webView.canGoBack
        case ItemID.forward: return webView.canGoForward
        default: return true
        }
    }
}

extension BrowserWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(navigateBack(_:)):
            return webView.canGoBack
        case #selector(navigateForward(_:)):
            return webView.canGoForward
        case #selector(stopLoadingPage(_:)):
            return webView.isLoading
        case #selector(toggleBookmark(_:)):
            guard let urlString = webView.url?.absoluteString,
                  !urlString.isEmpty, urlString != "about:blank",
                  !NewTabPage.isNewTabURL(webView.url) else {
                menuItem.title = "Add Bookmark"
                return false
            }
            menuItem.title = BookmarkStore.shared.containsBookmark(url: urlString) ? "Remove Bookmark" : "Add Bookmark"
            return true
        default:
            return true
        }
    }
}

// MARK: - URL field delegate

extension BrowserWindowController: NSTextFieldDelegate {

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === urlField else { return }
        typedTextBeforeSelection = nil
        refreshSuggestions()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === urlField else { return }
        suggestionsDropdown.hide()
        typedTextBeforeSelection = nil
        // Deferred deliberately. AppKit order is doCommandBy → this → the field's
        // action, so resetting the text here synchronously blanked the very string a
        // submission was about to read, and Return silently did nothing.
        DispatchQueue.main.async { [weak self] in
            self?.syncURLField(force: true)
        }
    }

    /// Arrow keys preview the highlighted suggestion in the field, and stepping off
    /// the list puts the user's own text back rather than stranding a suggestion.
    private func previewSelection(moving delta: Int, in textView: NSTextView) {
        if typedTextBeforeSelection == nil { typedTextBeforeSelection = textView.string }
        if let suggestion = suggestionsDropdown.moveSelection(by: delta) {
            urlField.stringValue = suggestion.title
        } else {
            urlField.stringValue = typedTextBeforeSelection ?? ""
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === urlField else { return false }

        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            suggestionsDropdown.hide()
            syncURLField(force: true)
            window?.makeFirstResponder(webView)
            return true

        case #selector(NSResponder.moveDown(_:)) where suggestionsDropdown.isVisible:
            previewSelection(moving: 1, in: textView)
            return true

        case #selector(NSResponder.moveUp(_:)) where suggestionsDropdown.isVisible:
            previewSelection(moving: -1, in: textView)
            return true

        case #selector(NSResponder.insertNewline(_:)):
            // Read the typed text HERE. This runs before the field ends editing, so it
            // is the last point at which the field still holds what the user typed.
            let typed = textView.string
            let selected = suggestionsDropdown.selectedSuggestion
            suggestionsDropdown.hide()
            typedTextBeforeSelection = nil
            // Handling it fully (returning true) also stops the default action from
            // firing, so the outcome no longer depends on AppKit's callback order.
            if let target = selected?.url ?? URLResolver.resolve(typed, privateSearch: isPrivate) {
                load(target)
                window?.makeFirstResponder(webView)
            }
            return true

        default:
            return false
        }
    }
}

// MARK: - WKNavigationDelegate

extension BrowserWindowController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let webSchemes = ["http", "https", "about", "file", "blob", "data", "javascript"]
        if !scheme.isEmpty, !webSchemes.contains(scheme) {
            // mailto:, facetime:, app deep links, etc. — hand off to the system.
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if navigationAction.targetFrame?.isMainFrame ?? false {
            // .other covers scripted and meta-refresh navigation; anything the user
            // actually triggered arrives as a link, a form, a reload or back/forward.
            pendingNavigationViaRedirect = !nextNavigationIsUserInitiated
                && navigationAction.navigationType == .other
            nextNavigationIsUserInitiated = false
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) {
            openInNewTab(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadsManager.shared.begin(download,
            suggestedName: navigationAction.request.url?.lastPathComponent ?? "Download")
        showDownloadsPopoverIfHidden()
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadsManager.shared.begin(download,
            suggestedName: navigationResponse.response.suggestedFilename ?? "Download")
        showDownloadsPopoverIfHidden()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let viaRedirect = pendingNavigationViaRedirect
        pendingNavigationViaRedirect = false
        if suppressHistoryOnce {
            suppressHistoryOnce = false
            return
        }
        guard !isPrivate, SuggestionEngine.shared.isEnabled,
              let url = webView.url,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        currentVisitID = HistoryStore.shared.record(url: url, viaRedirect: viaRedirect)
    }

    /// A server 3xx always means this page was a hop, never a destination the user chose.
    func webView(_ webView: WKWebView,
                 didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        pendingNavigationViaRedirect = true
    }

    /// Closes the previous visit the moment the tab starts going somewhere else — the
    /// dwell time this produces is what separates waypoints from real destinations.
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        closeCurrentVisit()
    }

    func closeCurrentVisit() {
        pauseActiveTiming()
        if let currentVisitID {
            HistoryStore.shared.closeVisit(id: currentVisitID, activeTime: activeAccumulated)
            self.currentVisitID = nil
        }
        activeAccumulated = 0
        // The tab is still in front, so attention on the next page starts immediately.
        resumeActiveTiming()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showErrorPage(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showErrorPage(error)
    }

    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
              challenge.previousFailureCount < 3,
              let window else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Sign in to \(challenge.protectionSpace.host)"
        alert.informativeText = "This site requires a username and password."
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let userField = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
        userField.placeholderString = "Username"
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        passwordField.placeholderString = "Password"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 58))
        container.addSubview(userField)
        container.addSubview(passwordField)
        alert.accessoryView = container
        alert.window.initialFirstResponder = userField

        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                let credential = URLCredential(user: userField.stringValue,
                                               password: passwordField.stringValue,
                                               persistence: .forSession)
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}

// MARK: - WKUIDelegate

extension BrowserWindowController: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank / window.open — must use the provided configuration as-is.
        let controller = BrowserWindowController(configuration: configuration, incognitoSession: incognitoSession)
        AppDelegate.shared.register(controller)
        attachAsTab(controller)
        return controller.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        window?.close()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        guard let window else { completionHandler(); return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty
            ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        guard let window else { completionHandler(false); return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty
            ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard let window else { completionHandler(nil); return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty
            ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        guard let window else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }
}

// MARK: - New tab page messages

extension BrowserWindowController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "rocket",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        switch action {
        case "retrain":
            SuggestionEngine.shared.retrain { [weak self] _ in
                // Regenerating the page is what shows the new chips.
                guard let self, NewTabPage.isNewTabURL(self.webView.url) else { return }
                NewTabPage.open(in: self.webView)
            }
        default:
            break
        }
    }
}

// MARK: - Downloads

extension BrowserWindowController: WKDownloadDelegate {

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var destination = downloadsDir.appendingPathComponent(suggestedFilename)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            destination = downloadsDir.appendingPathComponent(name)
            counter += 1
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloads.remove(download)
        NSApp.requestUserAttention(.informationalRequest)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.remove(download)
        NSLog("Download failed: \(error.localizedDescription)")
    }
}
