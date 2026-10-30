import UIKit
import WebKit

/// One tab: a web view plus the history bookkeeping the Mac's `BrowserWindowController`
/// does for its window. The tab is its own web view's navigation and UI delegate, so a
/// tab in the background still records history and follows redirects; anything that
/// needs the screen goes through `browser`.
final class Tab: NSObject {

    let webView: WKWebView
    /// Non-nil marks the tab incognito; every private tab shares one session, whose
    /// data store is destroyed when the last of them closes.
    let incognitoSession: IncognitoSession?
    var isPrivate: Bool { incognitoSession != nil }
    weak var browser: BrowserViewController?

    /// The card picture in the tab overview, taken whenever the tab leaves the screen.
    private(set) var snapshot: UIImage?

    /// A restored tab loads its page the first time it is shown, not all at launch.
    private var pendingURL: URL?
    private var pendingTitle: String?

    /// Open history visit for the page on screen, closed when the tab navigates away.
    private var currentVisitID: UUID?
    /// Set when the pending navigation was NOT started by the user (a redirect).
    private var pendingNavigationViaRedirect = false
    private var nextNavigationIsUserInitiated = false
    private var suppressHistoryOnce = false
    /// Showing Rocket's own start page, which is one screen rather than a document.
    private var onStartPage = false
    private var titleObservation: NSKeyValueObservation?
    /// Attention: seconds this tab was on screen with Rocket in the foreground.
    private var activeAccumulated: TimeInterval = 0
    private var activeSince: Date?

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Mobile Safari's own agent, for the Mac's reason: some sites (Google sign-in)
        // turn away the bare WKWebView one.
        configuration.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.allowsInlineMediaPlayback = true
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }

    /// A tab Rocket opens itself. Private tabs get the session's data store here.
    convenience init(incognitoSession: IncognitoSession?) {
        let configuration = Tab.makeConfiguration()
        if let store = incognitoSession?.dataStore {
            configuration.websiteDataStore = store
        }
        self.init(configuration: configuration, incognitoSession: incognitoSession)
    }

    convenience init(restoring url: URL, title: String?) {
        self.init(incognitoSession: nil)
        pendingURL = url
        pendingTitle = title
    }

    /// Popups come straight here: WebKit's configuration MUST be used as given, never
    /// a copy, or the page loses its handle on the window it opened.
    init(configuration: WKWebViewConfiguration, incognitoSession: IncognitoSession?) {
        self.incognitoSession = incognitoSession
        incognitoSession?.attach()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isFindInteractionEnabled = true
        // Lets Safari on a Mac inspect this tab (Develop ▸ <this iPhone>).
        webView.isInspectable = true
        if isPrivate { webView.overrideUserInterfaceStyle = .dark }

        ContentBlocker.shared.apply(to: webView, isIncognito: isPrivate)
        // One shared bridge for every tab, as on the Mac: popups share their opener's
        // content controller, so a per-tab handler would be torn out from under it.
        let userContent = configuration.userContentController
        userContent.removeScriptMessageHandler(forName: "rocket")
        userContent.add(NewTabPageBridge.shared, name: "rocket")

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.webView.reload() }, for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        // The title lands after the visit is recorded and can change while the page
        // is open, so the history row is stamped from here.
        titleObservation = webView.observe(\.title) { [weak self] webView, _ in
            if let id = self?.currentVisitID {
                HistoryStore.shared.setTitle(id: id, webView.title)
            }
        }
    }

    // MARK: - Loading

    func load(_ url: URL) {
        pendingURL = nil
        onStartPage = false
        // A typed URL or a bookmark is not a redirect hop.
        nextNavigationIsUserInitiated = true
        webView.load(URLRequest(url: url))
    }

    func openNewTabPage() {
        pendingURL = nil
        onStartPage = true
        webView.scrollView.isScrollEnabled = false
        // The normal start page renders chips learned from normal browsing.
        if isPrivate {
            NewTabPage.openIncognito(in: webView)
        } else {
            NewTabPage.open(in: webView)
        }
    }

    /// Called when the tab comes on screen.
    func loadIfRestored() {
        if let pendingURL { load(pendingURL) }
    }

    /// What the tab would restore to: the page it shows, or the one it has yet to load.
    var sessionURL: URL? { pendingURL ?? webView.url }

    var title: String {
        if let pendingURL { return pendingTitle ?? pendingURL.host ?? pendingURL.absoluteString }
        if NewTabPage.isInternalURL(webView.url) { return isPrivate ? "Incognito" : "New Tab" }
        let title = webView.title ?? ""
        return title.isEmpty ? (webView.url?.host ?? "New Tab") : title
    }

    /// Photographs the top of the page at card proportions (3:4) and card size, so
    /// a grid of tabs does not hold full-screen bitmaps. Best effort: WebKit only
    /// draws a view that is in a window, and a failed attempt keeps the old picture.
    func captureSnapshot(then completion: (() -> Void)? = nil) {
        let bounds = webView.bounds
        guard webView.window != nil, bounds.width > 0 else {
            completion?()
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: bounds.width,
                                    height: min(bounds.height, bounds.width * 4 / 3))
        configuration.snapshotWidth = 220
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            if let image { self?.snapshot = image }
            completion?()
        }
    }

    func close() {
        closeCurrentVisit()
        pauseActiveTiming()
        titleObservation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        // Last private tab out destroys the session's data store.
        incognitoSession?.detach()
    }

    // MARK: - Attention timing

    func resumeActiveTiming() {
        guard activeSince == nil, browser?.isFrontmost(self) ?? false else { return }
        activeSince = Date()
    }

    func pauseActiveTiming() {
        guard let since = activeSince else { return }
        activeAccumulated += Date().timeIntervalSince(since)
        activeSince = nil
    }

    private func closeCurrentVisit() {
        pauseActiveTiming()
        if let currentVisitID {
            HistoryStore.shared.closeVisit(id: currentVisitID, activeTime: activeAccumulated)
            self.currentVisitID = nil
        }
        activeAccumulated = 0
        resumeActiveTiming()
    }

    // MARK: - Error page

    private func showErrorPage(_ error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        // 102: frame load interrupted (e.g. a navigation became a download); 204: plugin handled.
        if nsError.domain == "WebKitErrorDomain", [102, 204].contains(nsError.code) { return }

        let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        suppressHistoryOnce = true
        let html = """
        <!doctype html>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <style>
            body { font-family: -apple-system, sans-serif; display: flex; align-items: center;
                   justify-content: center; height: 90vh; margin: 0 24px; }
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

// MARK: - WKNavigationDelegate

extension Tab: WKNavigationDelegate {

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
            // mailto:, tel:, app links — hand off to iOS. Only from the page itself:
            // a hidden iframe does not get to launch apps.
            if navigationAction.targetFrame?.isMainFrame ?? true {
                UIApplication.shared.open(url)
            }
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
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // `Content-Disposition: attachment` is the server saying "save this", even on
        // types WebKit could display — see the Mac controller for how that was found.
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let isAttachment = disposition.hasPrefix("attachment")
        decisionHandler(navigationResponse.canShowMIMEType && !isAttachment ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        began(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        began(download)
    }

    private func began(_ download: WKDownload) {
        download.delegate = Downloads.shared
        // A tab opened only to carry a download has nothing left to show.
        if webView.backForwardList.currentItem == nil {
            browser?.close(self)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.scrollView.refreshControl?.endRefreshing()
        let viaRedirect = pendingNavigationViaRedirect
        pendingNavigationViaRedirect = false
        if !isPrivate {
            browser?.scheduleSessionSave()
        }
        if suppressHistoryOnce {
            suppressHistoryOnce = false
            return
        }
        guard !isPrivate, SuggestionEngine.shared.isEnabled,
              let url = webView.url,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        currentVisitID = HistoryStore.shared.record(url: url, viaRedirect: viaRedirect)
        if let host = url.host { WaypointPreconnect.preconnect(from: webView, on: host) }
    }

    /// The start page neither scrolls nor bounces; anything after it does. The incognito
    /// start page sits at about:blank, so that URL only counts straight after opening it —
    /// a popup a site writes into about:blank must still scroll.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let url = webView.url
        onStartPage = NewTabPage.isNewTabURL(url) || (onStartPage && url?.absoluteString == "about:blank")
        webView.scrollView.isScrollEnabled = !onStartPage
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
              challenge.previousFailureCount < 3, let browser else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let alert = UIAlertController(title: "Sign in to \(challenge.protectionSpace.host)",
                                      message: "This site requires a username and password.",
                                      preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Username"; $0.textContentType = .username }
        alert.addTextField {
            $0.placeholder = "Password"
            $0.isSecureTextEntry = true
            $0.textContentType = .password
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completionHandler(.cancelAuthenticationChallenge, nil)
        })
        alert.addAction(UIAlertAction(title: "Sign In", style: .default) { _ in
            let credential = URLCredential(user: alert.textFields?[0].text ?? "",
                                           password: alert.textFields?[1].text ?? "",
                                           persistence: .forSession)
            completionHandler(.useCredential, credential)
        })
        if !browser.presentAlert(alert, from: self) {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - WKUIDelegate

extension Tab: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        browser?.openPopup(configuration: configuration, from: self)
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser?.close(self)
    }

    private func pageSays(_ frame: WKFrameInfo) -> String {
        frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: pageSays(frame), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        if browser?.presentAlert(alert, from: self) != true { completionHandler() }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: pageSays(frame), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        if browser?.presentAlert(alert, from: self) != true { completionHandler(false) }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: pageSays(frame), message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        if browser?.presentAlert(alert, from: self) != true { completionHandler(nil) }
    }

    /// Adds "Open in New Tab" to WebKit's own long-press menu for links.
    func webView(_ webView: WKWebView,
                 contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL else {
            completionHandler(nil)
            return
        }
        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            let newTab = UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                guard let self else { return }
                self.browser?.openTab(url, incognitoSession: self.incognitoSession, select: false)
            }
            return UIMenu(children: [newTab] + suggested)
        })
    }
}

// MARK: - New tab page messages

/// The new tab page's retrain button posts here. Routes on `message.webView`, never a
/// captured tab, for the popup reason documented on the Mac's bridge.
final class NewTabPageBridge: NSObject, WKScriptMessageHandler {

    static let shared = NewTabPageBridge()

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "rocket",
              let body = message.body as? [String: Any],
              body["action"] as? String == "retrain",
              let sender = message.webView else { return }
        SuggestionEngine.shared.retrain { _ in
            // Always redraw the page that asked, so its button cannot stay stuck.
            guard NewTabPage.isNewTabURL(sender.url) else { return }
            NewTabPage.open(in: sender)
        }
    }
}

// MARK: - Downloads

/// Plain downloads: saved into Documents/Downloads, which the Files app shows under
/// On My iPhone ▸ Rocket, then offered to a share sheet. No acceleration and no
/// scanning — `ChunkedDownload` and `VirusTotal` stay on the Mac.
final class Downloads: NSObject, WKDownloadDelegate {

    static let shared = Downloads()

    static let directory: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Downloads", isDirectory: true)
    }()

    var onFinish: ((URL) -> Void)?
    var onFailure: ((String, Error) -> Void)?
    /// WebKit does not keep a download's delegate bookkeeping for us.
    private var active: [WKDownload: URL] = [:]

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var destination = Self.directory.appendingPathComponent(suggestedFilename)
        var counter = 2
        while fileManager.fileExists(atPath: destination.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            destination = Self.directory.appendingPathComponent(name)
            counter += 1
        }
        active[download] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = active.removeValue(forKey: download) else { return }
        onFinish?(url)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let name = active.removeValue(forKey: download)?.lastPathComponent ?? "Download"
        onFailure?(name, error)
    }
}
