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
    private let findBar = FindBarView()
    private var findBarHeight: NSLayoutConstraint!
    private lazy var findController = FindController(webView: webView)
    private var isFindBarVisible: Bool { findBarHeight.constant > 0 }
    private var reloadToolbarItem: NSToolbarItem?
    private var bookmarkToolbarItem: NSToolbarItem?
    private var observations: [NSKeyValueObservation] = []
    private var bookmarkObserver: NSObjectProtocol?
    private var downloads = Set<WKDownload>()
    private var suppressHistoryOnce = false

    private let suggestionsDropdown = SuggestionsDropdown()
    /// Completion request currently on the wire, and the newest query typed while it
    /// was in flight. At most one request exists at a time; the newest text always wins.
    private var inFlightSuggestionQuery: String?
    private var pendingSuggestionQuery: String?
    /// The last completions received, reused while a newer request is in flight so the
    /// list keeps its shape instead of collapsing between keystrokes.
    private var lastRemoteQuery: String?
    private var lastRemoteItems: [String] = []
    private var downloadsToolbarItem: NSToolbarItem?
    private weak var downloadsButton: NSButton?
    private let downloadsPopover = NSPopover()
    /// The key button anchors both the account menu and the save bubble, so like the
    /// downloads item it has to be a real view rather than a plain image toolbar item.
    private weak var passwordsButton: NSButton?
    private let saveBubblePopover = NSPopover()
    private(set) lazy var passwordAutofill = PasswordAutofillController(owner: self)
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
        static let passwords = NSToolbarItem.Identifier("rocket.passwords")
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
        findBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bookmarksBar)
        content.addSubview(findBar)
        content.addSubview(webView)
        content.addSubview(progressBar)
        bookmarksBarHeight = bookmarksBar.heightAnchor.constraint(equalToConstant: 30)
        // Zero-height while hidden, matching how the bookmarks bar collapses.
        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bookmarksBar.topAnchor.constraint(equalTo: content.topAnchor),
            bookmarksBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bookmarksBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bookmarksBarHeight,
            findBar.topAnchor.constraint(equalTo: bookmarksBar.bottomAnchor),
            findBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            findBarHeight,
            webView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
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

        // The new tab page posts here. One shared bridge handles every tab: popups
        // inherit the opener's userContentController, so a per-controller handler got
        // torn out from under the opener whenever a popup registered or closed.
        let userContent = webView.configuration.userContentController
        userContent.removeScriptMessageHandler(forName: "rocket")
        userContent.add(NewTabPageBridge.shared, name: "rocket")

        // Autofill talks on its own isolated world, which is what keeps pages from
        // seeing or calling it. Same singleton-bridge rule as above.
        userContent.removeScriptMessageHandler(forName: PasswordAutofill.handlerName,
                                               contentWorld: PasswordAutofill.world)
        userContent.add(PasswordAutofillBridge.shared,
                        contentWorld: PasswordAutofill.world,
                        name: PasswordAutofill.handlerName)

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
        configureFindBar()
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
            guard let self, let url = self.webView.url, !NewTabPage.isInternalURL(url) else { return }
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

    // MARK: - Passwords

    /// The key button's menu: the accounts saved for this site, and a way into the
    /// manager. This is the fallback for pages where field detection finds nothing,
    /// so it fills whatever login form the page does have.
    @objc func showPasswordsMenu(_ sender: Any?) {
        let menu = NSMenu()
        let store = PasswordStore.shared
        if let url = webView.url, !NewTabPage.isInternalURL(url), let host = SiteMatcher.host(from: url) {
            let accounts = store.needsRestore ? [] : store.entries(for: host)
            if accounts.isEmpty {
                let empty = menu.addItem(withTitle: "No Saved Passwords for \(SiteMatcher.displayHost(host))",
                                         action: nil, keyEquivalent: "")
                empty.isEnabled = false
            }
            for entry in accounts {
                // A parent-domain match says which site it was actually saved under.
                let suffix = SiteMatcher.isExact(entryHost: entry.host, pageHost: host)
                    ? "" : " (\(SiteMatcher.displayHost(entry.host)))"
                let name = entry.username.isEmpty ? "password" : entry.username
                let item = menu.addItem(withTitle: "Fill \(name)\(suffix)",
                                        action: #selector(fillFromToolbar(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
            }
            menu.addItem(.separator())
        }
        let manage = menu.addItem(withTitle: "Manage Passwords…",
                                  action: #selector(AppDelegate.showPasswordsWindow(_:)), keyEquivalent: "")
        manage.target = AppDelegate.shared
        guard let button = passwordsButton else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    @objc private func fillFromToolbar(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        passwordAutofill.fillFromToolbar(entryID: id)
    }

    /// Where the account list and the save bubble hang when the page cannot say where
    /// its field is (a cross-origin frame): the key button, in screen coordinates.
    func passwordsAnchorScreenRect() -> NSRect? {
        guard let button = passwordsButton, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func presentSaveBubble(decision: SavePolicy.Decision, credential: PendingCredential) {
        guard window?.isVisible == true, let anchor = passwordsButton ?? window?.contentView else {
            credential.password.wipe()
            return
        }
        let bubble = PasswordSaveBubbleController(decision: decision, credential: credential)
        bubble.onSave = { [weak self] username in
            self?.saveBubblePopover.performClose(nil)
            self?.saveFromBubble(decision: decision, credential: credential, username: username)
        }
        bubble.onNever = { [weak self] in
            PasswordFlows.addNeverSave(host: credential.host)
            credential.password.wipe()
            self?.saveBubblePopover.performClose(nil)
        }
        bubble.onDismiss = { [weak self] in
            credential.password.wipe()
            self?.saveBubblePopover.performClose(nil)
        }
        saveBubblePopover.contentViewController = bubble
        saveBubblePopover.behavior = .semitransient
        let rect = anchor === passwordsButton
            ? anchor.bounds
            : NSRect(x: anchor.bounds.maxX - 80, y: anchor.bounds.maxY - 1, width: 32, height: 1)
        saveBubblePopover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
    }

    private func saveFromBubble(decision: SavePolicy.Decision, credential: PendingCredential, username: String) {
        PasswordFlows.ensureSetUp(from: window) { [weak self] ready in
            guard ready else { credential.password.wipe(); return }
            let store = PasswordStore.shared
            let site = SiteMatcher.displayHost(credential.host)
            let finish: (Result<Void, VaultError>) -> Void = { result in
                credential.password.wipe()
                if case .failure(let error) = result { PasswordFlows.present(error, in: self?.window) }
            }
            switch decision {
            case .offerUpdate(let entry):
                // Rocket could not tell whether the password actually changed without
                // unlocking first, so an identical one just refreshes "last used".
                let typed = credential.password.withString { $0 }
                store.mutate(reason: "update your password for \(site)", { index, secrets in
                    guard let position = index.entries.firstIndex(where: { $0.id == entry.id }),
                          var secret = secrets[entry.id] else { throw VaultError.corrupt }
                    if secret.password != typed {
                        secret.password = typed
                        secrets[entry.id] = secret
                        index.entries[position].modified = Date()
                    }
                    index.entries[position].username = username
                    index.entries[position].lastUsed = Date()
                }, completion: finish)
            default:
                let entry = PasswordEntry(host: credential.host, url: credential.url,
                                          username: username, lastUsed: Date())
                let secret = credential.password.withString {
                    PasswordSecret(password: $0, notes: nil, otpAuth: nil)
                }
                store.add(entry, secret: secret, reason: "save your password for \(site)", completion: finish)
            }
        }
    }

    // MARK: - Find in page

    private func configureFindBar() {
        findBar.isHidden = true
        findBar.onQueryChanged = { [weak self] text in
            self?.findController.search(text)
        }
        findBar.onNext = { [weak self] in self?.findController.step(1) }
        findBar.onPrevious = { [weak self] in self?.findController.step(-1) }
        findBar.onClose = { [weak self] in self?.hideFindBar(nil) }
        findController.onResults = { [weak self] total, index, scanning in
            self?.findBar.showResults(total: total, index: index, scanning: scanning)
        }
    }

    private func setFindBarVisible(_ visible: Bool) {
        guard visible != isFindBarVisible else { return }
        if visible { findBar.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            findBarHeight.animator().constant = visible ? FindBarView.barHeight : 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            if !self.isFindBarVisible { self.findBar.isHidden = true }
        }
    }

    // MARK: - Address bar suggestions

    private func refreshSuggestions() {
        // Read the field editor, not stringValue: it is the authority mid-edit.
        let text = urlField.currentEditor()?.string ?? urlField.stringValue
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            suggestionsDropdown.hide()
            lastRemoteQuery = nil
            lastRemoteItems = []
            return
        }
        // Draw on this keystroke, from local data plus any completions already known.
        renderSuggestions(for: text)
        requestRemoteSuggestions(for: text)
    }

    /// Everything that can be shown without waiting: bookmarks, history, the literal
    /// typed text, and cached (or carried-forward) engine completions.
    private func renderSuggestions(for text: String) {
        var results = AddressSuggestionProvider.local(for: text)
        // The literal typed text always leads, so Return does what it looks like.
        if let direct = URLResolver.resolve(text, privateSearch: isPrivate) {
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
                  let url = URLResolver.resolve(completion, privateSearch: isPrivate) else { continue }
            results.append(AddressSuggestion(kind: .search, title: completion, subtitle: nil, url: url))
        }
        suggestionsDropdown.show(results, below: urlField)
    }

    /// One request in flight at a time, no debounce. Typing while a request is out
    /// records the newest query and fires it the moment the current one lands — which
    /// keeps completions arriving continuously instead of only after a typing pause.
    private func requestRemoteSuggestions(for text: String) {
        if let hit = AddressSuggestionProvider.cached(for: text) {
            lastRemoteQuery = text
            lastRemoteItems = hit
            return                                  // already rendered from cache
        }
        guard inFlightSuggestionQuery == nil else {
            pendingSuggestionQuery = text
            return
        }
        inFlightSuggestionQuery = text
        AddressSuggestionProvider.remote(for: text, privateSearch: isPrivate) { [weak self] completions in
            guard let self else { return }
            self.inFlightSuggestionQuery = nil
            if !completions.isEmpty {
                self.lastRemoteQuery = text
                self.lastRemoteItems = completions
            }
            let current = self.urlField.currentEditor()?.string ?? self.urlField.stringValue
            if current == text, self.window?.firstResponder === self.urlField.currentEditor() {
                self.renderSuggestions(for: current)
            }
            if let pending = self.pendingSuggestionQuery {
                self.pendingSuggestionQuery = nil
                if pending != text { self.requestRemoteSuggestions(for: pending) }
            }
        }
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
            webView.observe(\.title) { [weak self] webView, _ in
                self?.updateWindowTitle()
                // The title lands after the visit is recorded, and can change again
                // while the page is open, so the history row is stamped from here.
                if let visitID = self?.currentVisitID {
                    HistoryStore.shared.setTitle(id: visitID, webView.title)
                }
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
        urlField.stringValue = NewTabPage.isInternalURL(webView.url)
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

    @objc func showFindBar(_ sender: Any?) {
        ImageTextScanner.warmUp()
        let wasVisible = isFindBarVisible
        setFindBarVisible(true)
        // Opening on a fresh selection searches for it, the way Safari does. An already
        // open bar just takes focus back so ⌘F never destroys what is being typed.
        guard !wasVisible else {
            findBar.focusField()
            return
        }
        findController.currentSelection { [weak self] selection in
            guard let self else { return }
            if !selection.isEmpty {
                self.findBar.field.stringValue = selection
                self.findController.search(selection, immediately: true)
            } else if !self.findBar.field.stringValue.isEmpty {
                self.findController.search(self.findBar.field.stringValue, immediately: true)
            }
            self.findBar.focusField()
        }
    }

    @objc func hideFindBar(_ sender: Any?) {
        setFindBarVisible(false)
        findController.clear()
        findBar.showResults(total: 0, index: -1, scanning: false)
        window?.makeFirstResponder(webView)
    }

    @objc func findNext(_ sender: Any?) {
        guard isFindBarVisible else { showFindBar(sender); return }
        findController.step(1)
    }

    @objc func findPrevious(_ sender: Any?) {
        guard isFindBarVisible else { showFindBar(sender); return }
        findController.step(-1)
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        findController.currentSelection { [weak self] selection in
            guard let self, !selection.isEmpty else { return }
            self.setFindBarVisible(true)
            self.findBar.field.stringValue = selection
            self.findController.search(selection, immediately: true)
        }
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
        // The panel is a child window that would otherwise float over whatever the
        // user switched to.
        passwordAutofill.hideDropdown()
    }

    func windowWillClose(_ notification: Notification) {
        // Stamp the dwell time for the page on screen, then offer the tab to ⇧⌘T.
        pauseActiveTiming()
        closeCurrentVisit()
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers.removeAll()
        suggestionsDropdown.hide()
        findController.teardown()
        // Drops any captured password on the floor rather than carrying it past the
        // tab that produced it. The script message handler is NOT removed: the bridge
        // is a shared singleton, exactly like NewTabPageBridge.
        passwordAutofill.teardown()
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
        // After unregister, so the debounced snapshot sees this tab already gone.
        // Quitting fires this for every window; the store coalesces those into one
        // write, and applicationWillTerminate flushes whatever is still pending.
        AppDelegate.shared.scheduleSessionSave()
    }
}

// MARK: - Toolbar

extension BrowserWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.back, ItemID.forward, .flexibleSpace,
         ItemID.urlField, .flexibleSpace, ItemID.reload, ItemID.bookmark,
         ItemID.passwords, ItemID.downloads]
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
        case ItemID.passwords:
            // A custom view for the same reason as downloads below: the account menu
            // and the save bubble both need a concrete anchor.
            let button = NSButton(image: NSImage(systemSymbolName: "key.fill",
                                                 accessibilityDescription: "Passwords")!,
                                  target: self, action: #selector(showPasswordsMenu(_:)))
            button.bezelStyle = .texturedRounded
            button.setButtonType(.momentaryPushIn)
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = "Passwords"
            item.toolTip = "Passwords"
            passwordsButton = button
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
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return isFindBarVisible || !findBar.field.stringValue.isEmpty
        case #selector(hideFindBar(_:)):
            return isFindBarVisible
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
        // A login submitted on the previous page is offered here: reaching a new page
        // is the closest thing to evidence that the sign-in worked.
        passwordAutofill.pageFinished()
        // A find bar left open should describe the page now on screen.
        if isFindBarVisible, !findBar.field.stringValue.isEmpty {
            findController.search(findBar.field.stringValue, immediately: true)
        }
        let viaRedirect = pendingNavigationViaRedirect
        pendingNavigationViaRedirect = false
        // Outside the history guards below: the session is what the tabs are showing,
        // which is worth saving even for a page that is never recorded in history.
        if !isPrivate {
            AppDelegate.shared.scheduleSessionSave()
        }
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
        // The engine was injected into the outgoing document; it leaves with it.
        findController.pageChanged()
        passwordAutofill.pageChanged()
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

extension BrowserWindowController {
    /// Confirms, then drops a host from the suggestion model and redraws the page.
    func confirmExcludeSuggestion(host: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Stop suggesting \(host)?"
        alert.informativeText = """
        \(host) will no longer appear as a new tab suggestion. Your history is not \
        changed, and you can undo this from Tools ▸ New Tab Suggestions ▸ Excluded Websites.
        """
        alert.addButton(withTitle: "Stop Suggesting")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            SuggestionEngine.shared.excludeHost(host)
            if NewTabPage.isNewTabURL(self.webView.url) {
                NewTabPage.open(in: self.webView)
            }
        }
    }
}

// MARK: - New tab page messages

/// Single handler for every tab's new tab page. It routes on `message.webView` rather
/// than on a captured controller, because popups share their opener's content
/// controller — a per-tab handler ended up reloading the wrong tab, and vanished
/// entirely when the popup closed, leaving the opener's button spinning forever.
final class NewTabPageBridge: NSObject, WKScriptMessageHandler {

    static let shared = NewTabPageBridge()

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "rocket",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let sender = message.webView else { return }
        let controller = AppDelegate.shared.controller(for: sender)

        switch action {
        case "excludeSuggestion":
            guard let host = body["host"] as? String, !host.isEmpty else { return }
            controller?.confirmExcludeSuggestion(host: host)

        case "retrain":
            SuggestionEngine.shared.retrain { _ in
                // Always redraw the page that asked, so its button cannot stay stuck.
                guard NewTabPage.isNewTabURL(sender.url) else { return }
                NewTabPage.open(in: sender)
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
