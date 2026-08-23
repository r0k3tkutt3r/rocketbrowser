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

    private enum ItemID {
        static let back = NSToolbarItem.Identifier("rocket.back")
        static let forward = NSToolbarItem.Identifier("rocket.forward")
        static let urlField = NSToolbarItem.Identifier("rocket.urlField")
        static let reload = NSToolbarItem.Identifier("rocket.reload")
        static let bookmark = NSToolbarItem.Identifier("rocket.bookmark")
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

        configureURLField()
        configureToolbar()
        startObservations()
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
        let urlString = webView.url?.absoluteString ?? ""
        let isInternal = urlString == "about:blank" || NewTabPage.isNewTabURL(webView.url)
        urlField.stringValue = isInternal ? "" : urlString
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
    }

    @objc func pageZoomOut(_ sender: Any?) {
        webView.pageZoom = max(webView.pageZoom - 0.1, 0.5)
    }

    @objc func pageZoomActual(_ sender: Any?) {
        webView.pageZoom = 1.0
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
    func windowWillClose(_ notification: Notification) {
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
         ItemID.urlField, .flexibleSpace, ItemID.reload, ItemID.bookmark]
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
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === urlField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            syncURLField(force: true)
            window?.makeFirstResponder(webView)
            return true
        }
        return false
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
        download.delegate = self
        downloads.insert(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        downloads.insert(download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if suppressHistoryOnce {
            suppressHistoryOnce = false
            return
        }
        guard !isPrivate, SuggestionEngine.shared.isEnabled,
              let url = webView.url,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        HistoryStore.shared.record(url: url)
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
