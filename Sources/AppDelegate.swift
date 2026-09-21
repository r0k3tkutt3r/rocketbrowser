import Cocoa
import UniformTypeIdentifiers
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {

    private(set) static var shared: AppDelegate!

    /// Override with: defaults write com.kushmodi.rocket Homepage "https://example.com"
    static var homepage: URL {
        if let custom = UserDefaults.standard.string(forKey: "Homepage"), let url = URL(string: custom) {
            return url
        }
        return URL(string: "https://www.google.com")!
    }

    private var controllers: [BrowserWindowController] = []
    private let bookmarksMenu = NSMenu(title: "Bookmarks")
    private let suggestionsMenu = NSMenu(title: "New Tab Suggestions")
    private let securityMenu = NSMenu(title: "Download Scanning")
    private let passwordsMenu = NSMenu(title: "Passwords")
    private let activityMenu = NSMenu(title: "Tab Activity")
    private let watchesMenu = NSMenu(title: "Watches")
    private let compareMenu = NSMenu(title: "Compare")
    /// The launch notification for changed watches, held while it is on screen.
    private var watchPopover: NSPopover?
    /// Recently closed tabs, newest last — the ⇧⌘T stack.
    private var closedTabs: [(url: URL, title: String?)] = []
    /// The session as it was at launch, read once and kept.
    ///
    /// It cannot be re-read from disk on demand: the live session overwrites
    /// session.json within seconds of launch, so by the time anyone reaches
    /// "Reopen Last Session" the file describes the empty tab they are looking at.
    /// Holding the launch-time copy in memory keeps the command working all run.
    private var previousSession: SavedSession?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = buildMainMenu()

        IncognitoSession.purgeLeftoverStores()
        // Picks up a key file (project folder or Application Support) into the keychain.
        VirusTotal.importKeyFromFileIfAvailable()

        observePasswordLockTriggers()
        // The manager window knows nothing about tabs; opening a site goes through here.
        PasswordsWindowController.openURL = { [weak self] url in
            guard let self else { return }
            if let front = self.frontNormalBrowserController {
                front.openInNewTab(url)
            } else {
                self.openNewWindow(url: url)
            }
        }

        ContentBlocker.shared.applyToAllWebViews = { [weak self] in
            guard let self else { return }
            for controller in self.controllers {
                ContentBlocker.shared.apply(to: controller.webView, isIncognito: controller.isPrivate)
                controller.webView.reload()
            }
        }
        ContentBlocker.shared.prepare { [weak self] in
            guard let self else { return }
            for controller in self.controllers {
                ContentBlocker.shared.apply(to: controller.webView, isIncognito: controller.isPrivate)
            }
        }

        SuggestionEngine.shared.retrainIfDue { [weak self] trained in
            if trained { self?.reloadNewTabPages() }
        }

        // MCP for AI agents. Incognito is filtered right here so no tool can see it.
        AgentServer.shared.context = AgentContext(
            tabs: { [weak self] in self?.controllers.filter { !$0.isPrivate } ?? [] },
            front: { [weak self] in self?.frontNormalBrowserController },
            open: { [weak self] url in
                guard let self else { fatalError("app delegate gone") }
                if let front = self.frontNormalBrowserController { return front.openInNewTab(url) }
                return self.openNewWindow(url: url)
            })
        if AgentServer.isEnabled { AgentServer.shared.start() }

        // A few syscalls per tab. It has to run whether or not anyone is looking,
        // because a CPU rate is a difference between two samples.
        let sampler = Timer.scheduledTimer(withTimeInterval: TabActivity.sampleInterval,
                                           repeats: true) { [weak self] _ in
            guard let self else { return }
            TabActivity.refresh(pids: self.controllers.compactMap { TabActivity.processID(of: $0.webView) })
        }
        sampler.tolerance = 10

        // Watched values. The timer only decides *when* a watch is due; the interval
        // that matters is the per-watch one, and the shortest of those is an hour.
        let watcher = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            PageWatchChecker.shared.checkDue()
        }
        watcher.tolerance = 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            PageWatchChecker.shared.checkDue()
        }
        NotificationCenter.default.addObserver(forName: .watchesDidChange, object: nil,
                                               queue: .main) { [weak self] _ in
            let unread = PageWatchStore.shared.unreadCount
            NSApp.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
            self?.reloadComparisonPages()
        }
        NotificationCenter.default.addObserver(forName: .comparisonLeaderChanged, object: nil,
                                               queue: .main) { [weak self] notification in
            self?.announceLeaderChange(notification)
        }
        let unread = PageWatchStore.shared.unreadCount
        NSApp.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil

        previousSession = SessionStore.shared.load()
        // ⇧⌘T picks up where the last run left off, not from an empty stack.
        closedTabs = (previousSession?.closedTabs ?? []).compactMap { tab in
            URL(string: tab.url).map { (url: $0, title: tab.title) }
        }

        if SessionStore.restoresOnLaunch, let session = previousSession, !session.isEmpty {
            restore(session)
        } else {
            openNewWindow(url: nil)
        }

        // Don't steal focus when launched hidden (e.g. `open -gj` for background testing).
        if !NSApp.isHidden {
            NSApp.activate()
        }
        // After the window is actually on screen: a popover has nothing to hang from
        // until then.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.announceWatchChanges()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        SuggestionEngine.shared.retrainIfDue { [weak self] trained in
            if trained { self?.reloadNewTabPages() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PasswordStore.shared.lockNow()
        HistoryStore.shared.flush()
        SessionStore.shared.flush { currentSessionSnapshot() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openNewWindow(url: nil) }
        return true
    }

    /// Links opened from other apps (Rocket can be chosen as the default browser).
    /// Always routed to a normal window — a link from Mail must never land in
    /// (or be influenced by) someone's incognito session.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let front = frontNormalBrowserController {
                front.openInNewTab(url)
            } else {
                openNewWindow(url: url)
            }
        }
    }

    // MARK: - Window management

    var frontBrowserController: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)
            ?? (NSApp.mainWindow?.windowController as? BrowserWindowController)
            ?? controllers.last
    }

    var frontNormalBrowserController: BrowserWindowController? {
        if let front = frontBrowserController, !front.isPrivate { return front }
        return controllers.last { !$0.isPrivate }
    }

    @discardableResult
    func openNewWindow(url: URL?,
                       configuration: WKWebViewConfiguration? = nil,
                       incognitoSession: IncognitoSession? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(
            configuration: configuration ?? BrowserWindowController.makeConfiguration(),
            incognitoSession: incognitoSession)
        register(controller)
        controller.showWindow(nil)
        if let url {
            controller.load(url)
        } else {
            controller.openNewTabPage()
        }
        return controller
    }

    /// Finds the controller owning a web view — used to route new tab page messages
    /// back to the tab that actually sent them.
    func controller(for webView: WKWebView) -> BrowserWindowController? {
        controllers.first { $0.webView === webView }
    }

    func register(_ controller: BrowserWindowController) {
        controllers.append(controller)
    }

    func unregister(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
    }

    // MARK: - Session

    /// Walks the live windows in the order they are shown — tab groups in the order
    /// their first tab was registered, tabs in tab-bar order — and reduces them to the
    /// plain values `SessionSnapshot` filters. Incognito windows and blank start pages
    /// are dropped there, not here.
    func currentSessionSnapshot() -> SavedSession {
        var entries: [SessionSnapshot.Entry] = []
        var emitted = Set<ObjectIdentifier>()
        var nextGroupKey = 0

        for controller in controllers {
            guard let window = controller.window,
                  !emitted.contains(ObjectIdentifier(controller)) else { continue }
            let groupKey = nextGroupKey
            nextGroupKey += 1

            // tabGroup.windows is the tab bar's own order; a lone window has no group.
            for tabWindow in window.tabGroup?.windows ?? [window] {
                guard let tabController = tabWindow.windowController as? BrowserWindowController,
                      controllers.contains(where: { $0 === tabController }),
                      emitted.insert(ObjectIdentifier(tabController)).inserted else { continue }
                entries.append(SessionSnapshot.Entry(
                    url: tabController.webView.url?.absoluteString ?? "",
                    title: tabController.webView.title,
                    groupKey: groupKey,
                    isPrivate: tabController.isPrivate,
                    isNewTabPage: NewTabPage.isNewTabURL(tabController.webView.url)))
            }
        }

        let closed = closedTabs.map { SessionTab(url: $0.url.absoluteString, title: $0.title) }
        return SessionSnapshot.build(from: entries, closedTabs: closed)
    }

    /// Called as tabs navigate and close. The write itself is debounced inside the
    /// store, and the snapshot is taken when the timer fires rather than now.
    func scheduleSessionSave() {
        SessionStore.shared.scheduleSave { [weak self] in
            self?.currentSessionSnapshot()
                ?? SavedSession(windows: [], closedTabs: [], savedAt: Date())
        }
    }

    /// Reopens a saved session: one window per saved window, its tabs in order.
    private func restore(_ session: SavedSession) {
        for savedWindow in session.windows {
            var host: BrowserWindowController?
            for tab in savedWindow.tabs {
                guard let url = URL(string: tab.url) else { continue }
                if let host {
                    host.openInNewTab(url)
                } else {
                    host = openNewWindow(url: url)
                }
            }
        }
        // A session of nothing but unparseable URLs must not leave a browser with no
        // window at all — there would be no way back except the Dock icon.
        if controllers.isEmpty {
            openNewWindow(url: nil)
        }
    }

    @objc func reopenLastSession(_ sender: Any?) {
        guard let previousSession, !previousSession.isEmpty else { return }
        restore(previousSession)
    }

    @objc func toggleSessionRestore(_ sender: Any?) {
        SessionStore.restoresOnLaunch.toggle()
    }

    // MARK: - AI agents

    @objc func toggleAgentAccess(_ sender: Any?) {
        AgentServer.isEnabled.toggle()
        if AgentServer.isEnabled { AgentServer.shared.start() } else { AgentServer.shared.stop() }
    }

    @objc func copyClaudeCodeSetup(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentServer.claudeCodeSetupCommand, forType: .string)
    }

    @objc func copyCodexSetup(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentServer.codexSetupSnippet, forType: .string)
    }

    // MARK: - Passwords

    @objc func showPasswordsWindow(_ sender: Any?) {
        PasswordsWindowController.shared.show()
    }

    @objc func importPasswords(_ sender: Any?) {
        PasswordFlows.importCSV(from: NSApp.keyWindow)
    }

    @objc func exportPasswords(_ sender: Any?) {
        PasswordFlows.exportCSV(from: NSApp.keyWindow)
    }

    @objc func lockPasswords(_ sender: Any?) {
        PasswordStore.shared.lockNow()
    }

    @objc func togglePasswordAutofill(_ sender: Any?) {
        PasswordFlows.autofillEnabled.toggle()
    }

    @objc func togglePasswordSaving(_ sender: Any?) {
        PasswordFlows.offersToSave.toggle()
    }

    @objc func togglePasswordSubmit(_ sender: Any?) {
        PasswordFlows.submitsAfterFill.toggle()
    }

    @objc func setPasswordsLockAfter(_ sender: NSMenuItem) {
        PasswordFlows.lockAfterSeconds = sender.tag
    }

    @objc func changeRecoveryKey(_ sender: Any?) {
        PasswordFlows.changeRecoveryKey(from: NSApp.keyWindow)
    }

    @objc func restorePasswords(_ sender: Any?) {
        PasswordFlows.promptRestore(from: NSApp.keyWindow) { _ in }
    }

    /// The decrypted vault key never survives the Mac going to sleep, the screen
    /// locking, or the session switching away — whatever "Lock After" says.
    private func observePasswordLockTriggers() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                PasswordStore.shared.lockNow()
            }
        }
        // Not posted on the workspace centre: screen lock is a distributed notification.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            PasswordStore.shared.lockNow()
        }
    }

    // MARK: - History window

    @objc func showHistoryWindow(_ sender: Any?) {
        HistoryWindowController.shared.show()
    }

    // MARK: - Actions

    @objc func newWindow(_ sender: Any?) {
        openNewWindow(url: nil)
    }

    /// Each incognito window starts its own session: a fresh UUID-identified data
    /// store on disk, destroyed when the session's last window closes. Tabs and
    /// popups spawned from the window share the session (configuration copies keep
    /// the same store); separate ⇧⌘N windows can't see each other's cookies.
    @objc func newIncognitoWindow(_ sender: Any?) {
        let session = IncognitoSession()
        let configuration = BrowserWindowController.makeConfiguration()
        if let dataStore = session.dataStore {
            configuration.websiteDataStore = dataStore
        }
        openNewWindow(url: nil, configuration: configuration, incognitoSession: session)
    }

    // MARK: - Reopening closed tabs

    /// Called by each window as it closes. Incognito tabs are never recorded.
    func recordClosedTab(url: URL, title: String?) {
        closedTabs.append((url, title))
        if closedTabs.count > 25 { closedTabs.removeFirst() }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let last = closedTabs.popLast() else { return }
        if let front = frontNormalBrowserController {
            front.openInNewTab(last.url)
        } else {
            openNewWindow(url: last.url)
        }
    }

    // MARK: - Downloads

    @objc func showDownloadsWindow(_ sender: Any?) {
        frontBrowserController?.showDownloads(sender)
    }

    // MARK: - Download scanning (VirusTotal)

    @objc func setVirusTotalKey(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "VirusTotal API Key"
        alert.informativeText = """
        Paste your personal VirusTotal API key. It is stored in your login keychain, \
        not in a preferences file. Leave the box empty to remove the stored key.
        """
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = VirusTotal.apiKey ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        VirusTotal.apiKey = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Points Rocket at a text file containing the key; it is re-read every launch.
    @objc func importVirusTotalKeyFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose a text file containing your VirusTotal API key"
        panel.allowedContentTypes = [.plainText, .text]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        VirusTotal.keyFilePath = url.path
        let alert = NSAlert()
        if VirusTotal.importKeyFromFileIfAvailable() {
            alert.messageText = "API key imported"
            alert.informativeText = "Rocket will re-read \(url.lastPathComponent) at every launch."
        } else {
            alert.messageText = "Couldn’t read a key from that file"
            alert.informativeText = "The file must contain just the API key as plain text."
        }
        alert.runModal()
    }

    @objc func setScanPolicy(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: VirusTotal.policy = .riskyOrLarge
        case 2: VirusTotal.policy = .everything
        default: VirusTotal.policy = .off
        }
    }

    @objc func toggleVirusTotalUploads(_ sender: Any?) {
        // Turning this on means unknown files are sent to VirusTotal, where they are
        // retained and shareable — worth an explicit confirmation, once.
        if !VirusTotal.uploadsUnknownFiles {
            let alert = NSAlert()
            alert.messageText = "Upload unknown files to VirusTotal?"
            alert.informativeText = """
            Rocket normally sends only a file's SHA-256 hash, which reveals nothing about \
            its contents. Uploading sends the file itself; VirusTotal keeps uploaded files \
            and shares them with its security-vendor partners. Only enable this for files \
            you would be comfortable making public.
            """
            alert.addButton(withTitle: "Enable Uploads")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        VirusTotal.uploadsUnknownFiles.toggle()
    }

    @objc func toggleSearchSuggestions(_ sender: Any?) {
        AddressSuggestionProvider.remoteEnabled.toggle()
    }

    @objc func toggleChunkedDownloads(_ sender: Any?) {
        ChunkedDownload.isEnabled.toggle()
    }

    /// Cmd+T falls through to here when no browser window is open.
    @objc func newWindowForTab(_ sender: Any?) {
        openNewWindow(url: nil)
    }

    // MARK: - Default browser

    /// Compares by bundle identifier, not path: Launch Services stores the default
    /// handler by identifier, so a second copy of Rocket elsewhere still counts.
    var isDefaultBrowser: Bool {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// Asks macOS directly instead of going through System Settings — this works even
    /// when the Settings dropdown misses Rocket (duplicate/stale Launch Services
    /// records for one bundle id are enough to confuse that list). macOS shows its own
    /// confirmation panel; setting https also settles http, so the second call
    /// normally completes without a further prompt.
    @objc func setAsDefaultBrowser(_ sender: Any?) {
        let appURL = Bundle.main.bundleURL

        // Running from build/ is a trap: build.sh deletes that bundle on every build,
        // which strands the default-browser setting on a path that no longer exists.
        if !appURL.path.hasPrefix("/Applications/") {
            let alert = NSAlert()
            alert.messageText = "Set this copy as the default browser?"
            alert.informativeText = """
            This copy of Rocket is running from:
            \(appURL.path)

            Rebuilding deletes and recreates that bundle, which can break the default \
            browser setting. Installing Rocket in /Applications and setting that copy \
            is more reliable.
            """
            alert.addButton(withTitle: "Set Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let workspace = NSWorkspace.shared
        workspace.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https") { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.presentDefaultBrowserFailure(error)
                    return
                }
                workspace.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http") { error in
                    DispatchQueue.main.async {
                        if let error {
                            self?.presentDefaultBrowserFailure(error)
                        }
                    }
                }
            }
        }
    }

    private func presentDefaultBrowserFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t set Rocket as the default browser"
        alert.informativeText = """
        \(error.localizedDescription)

        Stale Launch Services records are the usual cause — several registrations of \
        one app confuse the default-browser machinery. Re-registering this copy \
        usually clears it:

        lsregister -f -u <old path>
        """
        alert.runModal()
    }

    @objc func toggleBookmarksBar(_ sender: Any?) {
        let shown = UserDefaults.standard.object(forKey: "ShowBookmarksBar") as? Bool ?? true
        UserDefaults.standard.set(!shown, forKey: "ShowBookmarksBar")
        for controller in controllers {
            controller.updateBookmarksBarVisibility()
        }
    }

    @objc func toggleAdBlocking(_ sender: Any?) {
        ContentBlocker.shared.adsEnabled.toggle()
    }

    @objc func toggleCookieBanners(_ sender: Any?) {
        ContentBlocker.shared.cookieBannersHidden.toggle()
    }

    /// Strips "install Chrome" cards from Google's services (and the same shape of
    /// browser pitch anywhere else).
    @objc func togglePromoBlocking(_ sender: Any?) {
        PromoBlocker.isEnabled.toggle()
        ContentBlocker.shared.applyToAllWebViews?()
    }

    @objc func toggleFingerprintProtection(_ sender: Any?) {
        PrivacyShield.isEnabled.toggle()
        ContentBlocker.shared.applyToAllWebViews?()
    }

    /// Whether ⌘F also reads the text inside pictures. Local, on-device Vision work —
    /// the toggle is about the CPU it costs, not about anything leaving the machine.
    @objc func toggleImageTextSearch(_ sender: Any?) {
        ImageTextScanner.isEnabled.toggle()
    }

    @objc func chooseWallpaper(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try NewTabPage.setWallpaper(from: url)
                self?.reloadNewTabPages()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t set wallpaper"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    @objc func resetWallpaper(_ sender: Any?) {
        NewTabPage.clearWallpaper()
        reloadNewTabPages()
    }

    private func reloadNewTabPages() {
        for controller in controllers where NewTabPage.isNewTabURL(controller.webView.url) {
            NewTabPage.open(in: controller.webView)
        }
    }

    // MARK: - Suggestions

    @objc func toggleSuggestions(_ sender: Any?) {
        SuggestionEngine.shared.isEnabled.toggle()
        if SuggestionEngine.shared.isEnabled {
            SuggestionEngine.shared.retrainIfDue { [weak self] trained in
                if trained { self?.reloadNewTabPages() }
            }
        }
        reloadNewTabPages()
    }

    @objc func retrainSuggestions(_ sender: Any?) {
        SuggestionEngine.shared.retrain { [weak self] _ in
            self?.reloadNewTabPages()
        }
    }

    /// Drops a currently-suggested host straight from the menu.
    @objc func stopSuggestingHost(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }
        SuggestionEngine.shared.excludeHost(host)
        reloadNewTabPages()
    }

    @objc func excludeCurrentSite(_ sender: Any?) {
        guard let host = frontBrowserController?.webView.url?.host else { return }
        SuggestionEngine.shared.excludeHost(host)
        reloadNewTabPages()
    }

    @objc func includeSite(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }
        SuggestionEngine.shared.includeHost(host)
    }

    @objc func resetSuggestions(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Reset Suggestions Data?"
        alert.informativeText = "This deletes the locally stored visit history and the trained model. Bookmarks and website logins are not affected."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SuggestionEngine.shared.reset()
        reloadNewTabPages()
    }

    @objc func openBookmark(_ sender: NSMenuItem) {
        guard let bookmark = sender.representedObject as? Bookmark,
              let urlString = bookmark.url,
              let url = URL(string: urlString) else { return }
        if let front = frontBrowserController {
            front.load(url)
            front.window?.makeKeyAndOrderFront(nil)
        } else {
            openNewWindow(url: url)
        }
    }

    @objc func deleteBookmark(_ sender: NSMenuItem) {
        guard let bookmark = sender.representedObject as? Bookmark else { return }
        BookmarkStore.shared.removeItem(id: bookmark.id)
    }

    // MARK: - Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === bookmarksMenu {
            rebuildBookmarksMenu()
        } else if menu === suggestionsMenu {
            rebuildSuggestionsMenu()
        } else if menu === securityMenu {
            rebuildSecurityMenu()
        } else if menu === passwordsMenu {
            rebuildPasswordsMenu()
        } else if menu === activityMenu {
            rebuildActivityMenu()
        } else if menu === watchesMenu {
            rebuildWatchesMenu()
        } else if menu === compareMenu {
            rebuildCompareMenu()
        }
    }

    /// One row per comparison, cheapest value alongside. The page is where a comparison
    /// is actually read; this menu is how you get to it and how you add to it.
    private func rebuildCompareMenu() {
        compareMenu.removeAllItems()
        let add = compareMenu.addItem(withTitle: "Add This Value…",
                                      action: #selector(BrowserWindowController.compareSelectedValue(_:)),
                                      keyEquivalent: "")
        add.toolTip = "Select a price on the page first."
        compareMenu.addItem(withTitle: "Open Comparison Page",
                            action: #selector(openComparisonPage(_:)), keyEquivalent: "").target = self

        let groups = Comparison.groups(in: PageWatchStore.shared.watches)
        guard !groups.isEmpty else { return }
        compareMenu.addItem(.separator())
        for group in groups {
            let summary = group.lowest.map { "  —  cheapest \($0.value.prefix(24))" } ?? ""
            let parent = compareMenu.addItem(withTitle: "\(group.name.prefix(32))\(summary)",
                                             action: #selector(openComparisonPage(_:)), keyEquivalent: "")
            parent.target = self

            let submenu = NSMenu(title: group.name)
            for item in group.items {
                let title = "\(item.value.prefix(24))  —  \(item.host.prefix(32))"
                let row = submenu.addItem(withTitle: title, action: #selector(openWatch(_:)), keyEquivalent: "")
                row.representedObject = item.id
                row.target = self
                row.state = group.lowest?.id == item.id ? .on : .off
            }
            submenu.addItem(.separator())
            for (title, action) in [("Check Now", #selector(checkComparison(_:))),
                                    ("Delete Comparison", #selector(deleteComparison(_:)))] {
                let item = submenu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.representedObject = group.name
                item.target = self
            }
            compareMenu.setSubmenu(submenu, for: parent)
        }
    }

    /// Opens the comparison page in a tab — reusing the one already showing it rather
    /// than stacking up copies of a page that renders the same store every time.
    @objc func openComparisonPage(_ sender: Any?) {
        if let existing = controllers.first(where: { Comparison.isComparisonURL($0.webView.url) }) {
            Comparison.open(in: existing.webView)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let front = frontNormalBrowserController else {
            // Not `openNewWindow(url: nil)`: that starts the start page loading, which
            // the page below would then have to race. Same reason as `openBlankTab`.
            let controller = BrowserWindowController(configuration: BrowserWindowController.makeConfiguration())
            register(controller)
            controller.showWindow(nil)
            Comparison.open(in: controller.webView)
            return
        }
        Comparison.open(in: front.openBlankTab().webView)
    }

    @objc func checkComparison(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let group = Comparison.group(named: name, in: PageWatchStore.shared.watches) else { return }
        PageWatchChecker.shared.check(ids: group.items.map(\.id))
    }

    @objc func deleteComparison(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let group = Comparison.group(named: name, in: PageWatchStore.shared.watches) else { return }
        for item in group.items { PageWatchStore.shared.remove(id: item.id) }
    }

    /// The comparison page is a rendering of the store, so every store change rewrites
    /// whichever tab is showing it. That is also what puts a removed row or a fresh
    /// price on screen without anyone reloading anything.
    private func reloadComparisonPages() {
        for controller in controllers where Comparison.isComparisonURL(controller.webView.url) {
            Comparison.open(in: controller.webView)
        }
    }

    /// Someone went below someone else while Rocket was running. The Dock badge already
    /// carries "something changed"; this says which way, in the window in front of you.
    private func announceLeaderChange(_ notification: Notification) {
        guard let name = notification.userInfo?["comparison"] as? String,
              let id = notification.userInfo?["watch"] as? UUID,
              let leader = PageWatchStore.shared.watch(id: id),
              let anchor = frontNormalBrowserController?.window?.contentView else { return }
        let row = NSButton(title: "", target: self, action: #selector(openComparisonFromNotification(_:)))
        row.isBordered = false
        row.alignment = .left
        row.attributedTitle = NSAttributedString(
            string: "▼ \(leader.value.prefix(24))  —  \(leader.title.prefix(36))",
            attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 12)])
        let hint = NSTextField(labelWithString: "Open \(name)")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let popover = self.popover(heading: "New lowest price in \(name)", rows: [row, hint])
        popover.show(relativeTo: NSRect(x: anchor.bounds.maxX - 80, y: anchor.bounds.maxY - 1,
                                        width: 32, height: 1),
                     of: anchor, preferredEdge: .maxY)
        watchPopover = popover
    }

    @objc private func openComparisonFromNotification(_ sender: NSButton) {
        watchPopover?.performClose(nil)
        openComparisonPage(nil)
    }

    /// Every watched value, changed ones first. Opening this menu is what counts as
    /// having looked: the unread marks and the Dock badge clear on the way out.
    private func rebuildWatchesMenu() {
        watchesMenu.removeAllItems()
        let create = watchesMenu.addItem(withTitle: "Watch This Value…",
                                         action: #selector(BrowserWindowController.watchSelectedValue(_:)),
                                         keyEquivalent: "")
        create.toolTip = "Select a price or other value on the page first."
        let watches = PageWatchStore.shared.watches.sorted {
            ($0.unread ? 1 : 0, $0.changedAt ?? .distantPast) > ($1.unread ? 1 : 0, $1.changedAt ?? .distantPast)
        }
        guard !watches.isEmpty else { return }

        watchesMenu.addItem(.separator())
        let relative = RelativeDateTimeFormatter()
        for watch in watches {
            let arrow = watch.previousValue.flatMap {
                WatchValue.marker(for: WatchValue.compare(old: $0, new: watch.value))
            }
            let name = watch.title.isEmpty ? watch.host : watch.title
            let parent = watchesMenu.addItem(
                withTitle: (watch.unread ? "● " : "") + (arrow.map { "\($0) " } ?? "")
                    + "\(watch.value.prefix(32))  —  \(name.prefix(40))",
                action: nil, keyEquivalent: "")

            let submenu = NSMenu(title: name)
            let detail: String
            if watch.missingSince != nil {
                detail = "Couldn’t find this value on the page"
            } else if let previous = watch.previousValue {
                detail = "Was \(previous.prefix(32))"
            } else {
                detail = "No change yet"
            }
            submenu.addItem(withTitle: detail, action: nil, keyEquivalent: "").isEnabled = false
            if let checked = watch.checkedAt {
                let when = relative.localizedString(for: checked, relativeTo: Date())
                submenu.addItem(withTitle: "Checked \(when)", action: nil, keyEquivalent: "").isEnabled = false
            }
            submenu.addItem(.separator())
            for (title, action) in [("Open Page", #selector(openWatch(_:))),
                                    ("Check Now", #selector(checkWatchNow(_:))),
                                    ("Stop Watching", #selector(stopWatching(_:)))] {
                let item = submenu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.representedObject = watch.id
                item.target = self
            }
            watchesMenu.setSubmenu(submenu, for: parent)
        }
        watchesMenu.addItem(.separator())
        watchesMenu.addItem(withTitle: "Check All Now",
                            action: #selector(checkAllWatches(_:)), keyEquivalent: "").target = self
        PageWatchStore.shared.markAllRead()
    }

    @objc func openWatch(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        openWatch(id: id)
    }

    private func openWatch(id: UUID) {
        guard let watch = PageWatchStore.shared.watch(id: id),
              let url = URL(string: watch.url) else { return }
        if let front = frontNormalBrowserController {
            front.openInNewTab(url)
        } else {
            openNewWindow(url: url)
        }
    }

    /// The launch nudge: a popover in the front window when a watched value moved while
    /// Rocket was closed. The Dock badge is already there, but nobody inspects the Dock
    /// icon they have just clicked, which is exactly when the news is wanted.
    ///
    /// It deliberately does NOT mark anything read — dismissing a popover is not the same
    /// as having looked at the list, and the ● marks in Tools ▸ Watches are what carry the
    /// news the rest of the run. The announcement stamp is what keeps it from repeating.
    private func announceWatchChanges() {
        let announced = UserDefaults.standard.object(forKey: "WatchesAnnouncedAt") as? Date ?? .distantPast
        let changed = PageWatch.unannounced(in: PageWatchStore.shared.watches, since: announced)
        guard !changed.isEmpty, let anchor = frontNormalBrowserController?.window?.contentView else { return }
        UserDefaults.standard.set(Date(), forKey: "WatchesAnnouncedAt")

        let popover = watchNotificationPopover(for: changed)
        // Top-right of the page area, the same corner the save bubble falls back to.
        popover.show(relativeTo: NSRect(x: anchor.bounds.maxX - 80, y: anchor.bounds.maxY - 1,
                                        width: 32, height: 1),
                     of: anchor, preferredEdge: .maxY)
        watchPopover = popover
    }

    /// The notification itself: a heading, one clickable row per changed watch, and what
    /// the value used to be under each. Separate from the launch check above so it can be
    /// built and inspected without an app around it.
    func watchNotificationPopover(for changed: [PageWatch]) -> NSPopover {
        var rows: [NSView] = []
        for watch in changed.prefix(5) {
            let arrow = watch.previousValue.flatMap {
                WatchValue.marker(for: WatchValue.compare(old: $0, new: watch.value))
            } ?? "•"
            let name = watch.title.isEmpty ? watch.host : watch.title
            let row = NSButton(title: "", target: self, action: #selector(openWatchFromNotification(_:)))
            row.isBordered = false
            row.alignment = .left
            row.attributedTitle = NSAttributedString(
                string: "\(arrow) \(watch.value.prefix(24))  —  \(name.prefix(36))",
                attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 12)])
            row.cell?.representedObject = watch.id
            rows.append(row)
            if let previous = watch.previousValue {
                let was = NSTextField(labelWithString: "Was \(previous.prefix(24))")
                was.font = .systemFont(ofSize: 11)
                was.textColor = .secondaryLabelColor
                rows.append(was)
            }
        }

        return popover(heading: changed.count == 1
            ? "A watched value changed" : "\(changed.count) watched values changed", rows: rows)
    }

    /// The shell every one of these notifications shares: a bold heading, a column of
    /// rows, and a transient popover sized to fit them.
    private func popover(heading: String, rows: [NSView]) -> NSPopover {
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let stack = NSStackView(views: [title] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 0))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])
        stack.layoutSubtreeIfNeeded()
        let content = NSViewController()
        content.view = container
        content.preferredContentSize = NSSize(width: 320, height: stack.fittingSize.height + 32)

        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        return popover
    }

    @objc private func openWatchFromNotification(_ sender: NSButton) {
        watchPopover?.performClose(nil)
        guard let id = sender.cell?.representedObject as? UUID else { return }
        openWatch(id: id)
    }

    @objc func checkWatchNow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        PageWatchChecker.shared.check(ids: [id])
    }

    @objc func stopWatching(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        PageWatchStore.shared.remove(id: id)
    }

    @objc func checkAllWatches(_ sender: Any?) {
        PageWatchChecker.shared.check(ids: PageWatchStore.shared.watches.map(\.id))
    }

    /// One row per tab, worst offender first. Rebuilt on open from the sampler's last
    /// readings — nothing here touches the pages themselves, so opening this menu cannot
    /// wake the very background tabs it is reporting on.
    private func rebuildActivityMenu() {
        activityMenu.removeAllItems()
        let tabs = controllers.map { (controller: $0, pid: TabActivity.processID(of: $0.webView)) }
        guard !tabs.isEmpty else {
            activityMenu.addItem(withTitle: "No Open Tabs", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        var tabsPerProcess: [pid_t: Int] = [:]
        for pid in tabs.compactMap(\.pid) { tabsPerProcess[pid, default: 0] += 1 }

        let rows = tabs.map { tab in
            (controller: tab.controller,
             reading: tab.pid.flatMap { TabActivity.reading(for: $0) },
             shared: tab.pid.map { tabsPerProcess[$0, default: 0] > 1 } ?? false)
        }.sorted {
            ($0.reading?.cpuPercent ?? -1, $0.reading?.memoryBytes ?? 0)
                > ($1.reading?.cpuPercent ?? -1, $1.reading?.memoryBytes ?? 0)
        }

        for row in rows {
            // An incognito tab's page title has no business in a menu that lists it.
            let name = row.controller.isPrivate
                ? "Incognito"
                : (row.controller.webView.title ?? row.controller.webView.url?.host ?? "New Tab")
            let item = activityMenu.addItem(
                withTitle: "\(TabActivity.describe(row.reading))\(row.shared ? " (shared)" : "")"
                    + "  —  \(name.prefix(48))",
                action: #selector(focusTab(_:)), keyEquivalent: "")
            item.representedObject = row.controller
            item.target = self
        }
        if rows.contains(where: \.shared) {
            activityMenu.addItem(.separator())
            let note = activityMenu.addItem(
                withTitle: "Tabs on one site share a web process, and its figures.",
                action: nil, keyEquivalent: "")
            note.isEnabled = false
        }
    }

    @objc func focusTab(_ sender: NSMenuItem) {
        guard let controller = sender.representedObject as? BrowserWindowController,
              controllers.contains(where: { $0 === controller }),
              let window = controller.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Reapplies scripts the way the other script-backed toggles do: the hover half of
    /// this feature is a user script, so flipping it has to reach the open tabs.
    @objc func togglePreconnect(_ sender: Any?) {
        WaypointPreconnect.isEnabled.toggle()
        ContentBlocker.shared.applyToAllWebViews?()
    }

    /// Rebuilt on open because the last item flips between "Change Recovery Key" and
    /// "Restore from Recovery Key" depending on whether this Mac can open the vault.
    private func rebuildPasswordsMenu() {
        // `needsRestore` is a plain stored property, so it is only meaningful after the
        // store has tried to open the file. Without this the first open of the menu on
        // a Mac holding someone else's vault offers "Change Recovery Key…" instead of
        // the restore it actually needs.
        _ = PasswordStore.shared.isSetUp
        passwordsMenu.removeAllItems()
        let show = passwordsMenu.addItem(withTitle: "Show Passwords…",
                                         action: #selector(showPasswordsWindow(_:)), keyEquivalent: "p")
        show.keyEquivalentModifierMask = [.command, .option]
        passwordsMenu.addItem(withTitle: "Import from CSV…",
                              action: #selector(importPasswords(_:)), keyEquivalent: "")
        passwordsMenu.addItem(withTitle: "Export to CSV…",
                              action: #selector(exportPasswords(_:)), keyEquivalent: "")
        passwordsMenu.addItem(withTitle: "Lock Now",
                              action: #selector(lockPasswords(_:)), keyEquivalent: "")
        passwordsMenu.addItem(.separator())
        passwordsMenu.addItem(withTitle: "Autofill Passwords",
                              action: #selector(togglePasswordAutofill(_:)), keyEquivalent: "")
        passwordsMenu.addItem(withTitle: "Offer to Save Passwords",
                              action: #selector(togglePasswordSaving(_:)), keyEquivalent: "")
        passwordsMenu.addItem(withTitle: "Sign In After Filling",
                              action: #selector(togglePasswordSubmit(_:)), keyEquivalent: "")
        let lockMenu = NSMenu(title: "Lock After")
        for choice in PasswordFlows.lockAfterChoices {
            let item = lockMenu.addItem(withTitle: choice.title,
                                        action: #selector(setPasswordsLockAfter(_:)), keyEquivalent: "")
            item.tag = choice.seconds
            item.target = self
        }
        let lockParent = passwordsMenu.addItem(withTitle: "Lock After", action: nil, keyEquivalent: "")
        passwordsMenu.setSubmenu(lockMenu, for: lockParent)
        passwordsMenu.addItem(.separator())
        if PasswordStore.shared.needsRestore {
            passwordsMenu.addItem(withTitle: "Restore from Recovery Key…",
                                  action: #selector(restorePasswords(_:)), keyEquivalent: "")
        } else {
            passwordsMenu.addItem(withTitle: "Change Recovery Key…",
                                  action: #selector(changeRecoveryKey(_:)), keyEquivalent: "")
        }
    }

    private func rebuildSecurityMenu() {
        securityMenu.removeAllItems()
        let keyItem = securityMenu.addItem(withTitle: VirusTotal.hasAPIKey
                                            ? "Change VirusTotal API Key…" : "Set VirusTotal API Key…",
                                           action: #selector(setVirusTotalKey(_:)), keyEquivalent: "")
        keyItem.target = self
        let importItem = securityMenu.addItem(withTitle: "Use API Key File…",
                                              action: #selector(importVirusTotalKeyFile(_:)), keyEquivalent: "")
        importItem.target = self
        if let path = VirusTotal.keyFilePath, !path.isEmpty {
            let note = securityMenu.addItem(
                withTitle: "    reading \((path as NSString).lastPathComponent)",
                action: nil, keyEquivalent: "")
            note.isEnabled = false
        }
        securityMenu.addItem(.separator())

        for (title, tag) in [("Don't Scan Downloads", 0),
                             ("Scan Risky or Large Files", 1),
                             ("Scan Every Download", 2)] {
            let item = securityMenu.addItem(withTitle: title,
                                            action: #selector(setScanPolicy(_:)), keyEquivalent: "")
            item.tag = tag
            item.target = self
        }
        securityMenu.addItem(.separator())
        let uploadItem = securityMenu.addItem(withTitle: "Upload Unknown Files for Analysis",
                                              action: #selector(toggleVirusTotalUploads(_:)), keyEquivalent: "")
        uploadItem.target = self
        let note = securityMenu.addItem(
            withTitle: "Without uploads, only a file's hash is sent.", action: nil, keyEquivalent: "")
        note.isEnabled = false
    }

    private func rebuildSuggestionsMenu() {
        suggestionsMenu.removeAllItems()
        suggestionsMenu.addItem(withTitle: "Show Suggestions",
                                action: #selector(toggleSuggestions(_:)), keyEquivalent: "")
        suggestionsMenu.addItem(.separator())
        suggestionsMenu.addItem(withTitle: "Retrain Now",
                                action: #selector(retrainSuggestions(_:)), keyEquivalent: "")
        suggestionsMenu.addItem(withTitle: "Exclude Current Website",
                                action: #selector(excludeCurrentSite(_:)), keyEquivalent: "")

        let excludedMenu = NSMenu(title: "Excluded Websites")
        let excluded = SuggestionEngine.shared.excludedHosts
        if excluded.isEmpty {
            excludedMenu.addItem(withTitle: "None", action: nil, keyEquivalent: "")
        } else {
            for host in excluded {
                let item = excludedMenu.addItem(withTitle: "Include \(host) Again",
                                                action: #selector(includeSite(_:)), keyEquivalent: "")
                item.representedObject = host
            }
        }
        // The chips themselves, listed so they can be dropped without visiting them —
        // "Exclude Current Website" is unavailable on the new tab page, which has no host.
        let currentMenu = NSMenu(title: "Stop Suggesting")
        let shown = SuggestionEngine.shared.suggestions()
        if shown.isEmpty {
            currentMenu.addItem(withTitle: "No suggestions right now",
                                action: nil, keyEquivalent: "").isEnabled = false
        } else {
            for suggestion in shown {
                let item = currentMenu.addItem(withTitle: suggestion.host,
                                               action: #selector(stopSuggestingHost(_:)),
                                               keyEquivalent: "")
                item.representedObject = suggestion.host
                item.target = self
            }
        }
        let currentParent = suggestionsMenu.addItem(withTitle: "Stop Suggesting",
                                                    action: nil, keyEquivalent: "")
        suggestionsMenu.setSubmenu(currentMenu, for: currentParent)

        let excludedParent = suggestionsMenu.addItem(withTitle: "Excluded Websites",
                                                     action: nil, keyEquivalent: "")
        suggestionsMenu.setSubmenu(excludedMenu, for: excludedParent)

        // Hosts the browser worked out are sign-in hops or redirectors on its own.
        let autoMenu = NSMenu(title: "Detected Redirects")
        let detected = SuggestionEngine.shared.autoExclusionReasons
        if detected.isEmpty {
            autoMenu.addItem(withTitle: "None detected yet", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            for entry in detected {
                let item = autoMenu.addItem(withTitle: entry.host, action: nil, keyEquivalent: "")
                item.toolTip = entry.reason
                item.isEnabled = false
                let detail = autoMenu.addItem(withTitle: "    \(entry.reason)", action: nil, keyEquivalent: "")
                detail.isEnabled = false
            }
        }
        let autoParent = suggestionsMenu.addItem(withTitle: "Auto-Excluded Redirects",
                                                 action: nil, keyEquivalent: "")
        suggestionsMenu.setSubmenu(autoMenu, for: autoParent)

        suggestionsMenu.addItem(.separator())
        suggestionsMenu.addItem(withTitle: "Reset Suggestions Data…",
                                action: #selector(resetSuggestions(_:)), keyEquivalent: "")
    }

    private func rebuildBookmarksMenu() {
        bookmarksMenu.removeAllItems()
        bookmarksMenu.addItem(withTitle: "Add Bookmark",
                              action: #selector(BrowserWindowController.toggleBookmark(_:)),
                              keyEquivalent: "d")
        bookmarksMenu.addItem(.separator())

        let items = BookmarkStore.shared.items
        guard !items.isEmpty else {
            bookmarksMenu.addItem(withTitle: "No Bookmarks", action: nil, keyEquivalent: "")
            return
        }

        for item in items {
            if item.isFolder {
                let folderItem = bookmarksMenu.addItem(withTitle: item.title, action: nil, keyEquivalent: "")
                folderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
                let submenu = NSMenu(title: item.title)
                for child in item.children ?? [] where !child.isFolder {
                    let childItem = submenu.addItem(withTitle: child.title,
                                                    action: #selector(openBookmark(_:)),
                                                    keyEquivalent: "")
                    childItem.representedObject = child
                }
                if submenu.items.isEmpty {
                    let empty = submenu.addItem(withTitle: "Empty Folder", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                }
                bookmarksMenu.setSubmenu(submenu, for: folderItem)
            } else {
                let menuItem = bookmarksMenu.addItem(withTitle: item.title,
                                                     action: #selector(openBookmark(_:)),
                                                     keyEquivalent: "")
                menuItem.representedObject = item
            }
        }

        bookmarksMenu.addItem(.separator())
        let deleteMenu = NSMenu(title: "Delete Bookmark")
        addDeleteItems(items, to: deleteMenu, prefix: "")
        let deleteItem = bookmarksMenu.addItem(withTitle: "Delete Bookmark", action: nil, keyEquivalent: "")
        bookmarksMenu.setSubmenu(deleteMenu, for: deleteItem)
    }

    private func addDeleteItems(_ list: [Bookmark], to menu: NSMenu, prefix: String) {
        for item in list {
            let title = prefix + item.title + (item.isFolder ? " (folder)" : "")
            let menuItem = menu.addItem(withTitle: title,
                                        action: #selector(deleteBookmark(_:)),
                                        keyEquivalent: "")
            menuItem.representedObject = item
            if let children = item.children {
                addDeleteItems(children, to: menu, prefix: prefix + item.title + " / ")
            }
        }
    }

    private func addSubmenu(_ title: String, to parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = addSubmenu("Rocket", to: main)
        appMenu.addItem(withTitle: "About Rocket",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Set Rocket as Default Browser",
                        action: #selector(setAsDefaultBrowser(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Rocket", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Rocket", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = addSubmenu("File", to: main)
        fileMenu.addItem(withTitle: "New Tab",
                         action: #selector(NSResponder.newWindowForTab(_:)),
                         keyEquivalent: "t")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Incognito Window",
                         action: #selector(newIncognitoWindow(_:)),
                         keyEquivalent: "N")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Open Location…",
                         action: #selector(BrowserWindowController.focusAddressBar(_:)),
                         keyEquivalent: "l")
        fileMenu.addItem(withTitle: "Open File…",
                         action: #selector(BrowserWindowController.openFile(_:)),
                         keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = addSubmenu("Edit", to: main)
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findParent = editMenu.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(withTitle: "Find…",
                         action: #selector(BrowserWindowController.showFindBar(_:)),
                         keyEquivalent: "f")
        findMenu.addItem(withTitle: "Find Next",
                         action: #selector(BrowserWindowController.findNext(_:)),
                         keyEquivalent: "g")
        let findPrevious = findMenu.addItem(withTitle: "Find Previous",
                                            action: #selector(BrowserWindowController.findPrevious(_:)),
                                            keyEquivalent: "G")
        findPrevious.keyEquivalentModifierMask = [.command, .shift]
        findMenu.addItem(withTitle: "Use Selection for Find",
                         action: #selector(BrowserWindowController.useSelectionForFind(_:)),
                         keyEquivalent: "e")
        findMenu.addItem(withTitle: "Hide Find Bar",
                         action: #selector(BrowserWindowController.hideFindBar(_:)),
                         keyEquivalent: "")
        editMenu.setSubmenu(findMenu, for: findParent)

        let viewMenu = addSubmenu("View", to: main)
        viewMenu.addItem(withTitle: "Reload Page",
                         action: #selector(BrowserWindowController.reloadPage(_:)),
                         keyEquivalent: "r")
        viewMenu.addItem(withTitle: "Stop Loading",
                         action: #selector(BrowserWindowController.stopLoadingPage(_:)),
                         keyEquivalent: ".")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Actual Size",
                         action: #selector(BrowserWindowController.pageZoomActual(_:)),
                         keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Zoom In",
                         action: #selector(BrowserWindowController.pageZoomIn(_:)),
                         keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out",
                         action: #selector(BrowserWindowController.pageZoomOut(_:)),
                         keyEquivalent: "-")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Hide Bookmarks Bar",
                         action: #selector(toggleBookmarksBar(_:)),
                         keyEquivalent: "B")
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen",
                                          action: #selector(NSWindow.toggleFullScreen(_:)),
                                          keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        let historyMenu = addSubmenu("History", to: main)
        historyMenu.addItem(withTitle: "Back",
                            action: #selector(BrowserWindowController.navigateBack(_:)),
                            keyEquivalent: "[")
        historyMenu.addItem(withTitle: "Forward",
                            action: #selector(BrowserWindowController.navigateForward(_:)),
                            keyEquivalent: "]")
        let reopen = historyMenu.addItem(withTitle: "Reopen Last Closed Tab",
                                         action: #selector(reopenClosedTab(_:)),
                                         keyEquivalent: "T")
        reopen.keyEquivalentModifierMask = [.command, .shift]
        historyMenu.addItem(withTitle: "Reopen Last Session",
                            action: #selector(reopenLastSession(_:)),
                            keyEquivalent: "")
        historyMenu.addItem(.separator())
        historyMenu.addItem(withTitle: "Show History",
                            action: #selector(showHistoryWindow(_:)),
                            keyEquivalent: "y")
        historyMenu.addItem(.separator())
        historyMenu.addItem(withTitle: "Home",
                            action: #selector(BrowserWindowController.goHome(_:)),
                            keyEquivalent: "H")

        let bookmarksItem = NSMenuItem(title: "Bookmarks", action: nil, keyEquivalent: "")
        bookmarksItem.submenu = bookmarksMenu
        bookmarksMenu.delegate = self
        main.addItem(bookmarksItem)
        rebuildBookmarksMenu()

        // Develop: commands for the page in front of you, kept out of View because a
        // browser's inspector lives in its own menu everywhere else.
        let developMenu = addSubmenu("Develop", to: main)
        let inspectorItem = developMenu.addItem(
            withTitle: "Show Web Inspector",
            action: #selector(BrowserWindowController.showWebInspector(_:)), keyEquivalent: "i")
        inspectorItem.keyEquivalentModifierMask = [.command, .option]
        let consoleItem = developMenu.addItem(
            withTitle: "Show JavaScript Console",
            action: #selector(BrowserWindowController.showJavaScriptConsole(_:)), keyEquivalent: "c")
        consoleItem.keyEquivalentModifierMask = [.command, .option]
        developMenu.addItem(.separator())
        let sourceItem = developMenu.addItem(
            withTitle: "View Page Source",
            action: #selector(BrowserWindowController.viewPageSource(_:)), keyEquivalent: "u")
        sourceItem.keyEquivalentModifierMask = [.command, .option]
        let hardReload = developMenu.addItem(
            withTitle: "Reload Ignoring Cache",
            action: #selector(BrowserWindowController.reloadIgnoringCache(_:)), keyEquivalent: "R")
        hardReload.keyEquivalentModifierMask = [.command, .shift]

        // Tools: everything that changes how Rocket behaves, as opposed to the View
        // menu's commands for the page currently on screen.
        let toolsMenu = addSubmenu("Tools", to: main)
        toolsMenu.addItem(withTitle: "Block Ads and Trackers",
                          action: #selector(toggleAdBlocking(_:)),
                          keyEquivalent: "")
        toolsMenu.addItem(withTitle: "Hide Cookie Banners",
                          action: #selector(toggleCookieBanners(_:)),
                          keyEquivalent: "")
        toolsMenu.addItem(withTitle: "Fingerprinting Protection",
                          action: #selector(toggleFingerprintProtection(_:)),
                          keyEquivalent: "")
        toolsMenu.addItem(withTitle: "Hide Browser Install Prompts",
                          action: #selector(togglePromoBlocking(_:)),
                          keyEquivalent: "")
        toolsMenu.addItem(withTitle: "Search Suggestions",
                          action: #selector(toggleSearchSuggestions(_:)),
                          keyEquivalent: "")
        toolsMenu.addItem(withTitle: "Search Text in Images",
                          action: #selector(toggleImageTextSearch(_:)),
                          keyEquivalent: "")
        toolsMenu.addItem(withTitle: "Speed Up Links and Redirects",
                          action: #selector(togglePreconnect(_:)),
                          keyEquivalent: "")
        toolsMenu.addItem(withTitle: "Restore Tabs on Launch",
                          action: #selector(toggleSessionRestore(_:)),
                          keyEquivalent: "")
        let agentParent = toolsMenu.addItem(withTitle: "AI Agent Access", action: nil, keyEquivalent: "")
        let agentMenu = NSMenu(title: "AI Agent Access")
        agentMenu.addItem(withTitle: "Allow Agents to Control Rocket",
                          action: #selector(toggleAgentAccess(_:)),
                          keyEquivalent: "")
        agentMenu.addItem(.separator())
        agentMenu.addItem(withTitle: "Copy Claude Code Setup Command",
                          action: #selector(copyClaudeCodeSetup(_:)),
                          keyEquivalent: "")
        agentMenu.addItem(withTitle: "Copy Codex Setup Snippet",
                          action: #selector(copyCodexSetup(_:)),
                          keyEquivalent: "")
        toolsMenu.setSubmenu(agentMenu, for: agentParent)
        toolsMenu.addItem(.separator())
        let downloadsItem = toolsMenu.addItem(withTitle: "Show Downloads",
                                              action: #selector(showDownloadsWindow(_:)),
                                              keyEquivalent: "l")
        downloadsItem.keyEquivalentModifierMask = [.command, .option]
        let securityParent = toolsMenu.addItem(withTitle: "Download Scanning", action: nil, keyEquivalent: "")
        securityMenu.delegate = self
        toolsMenu.setSubmenu(securityMenu, for: securityParent)
        rebuildSecurityMenu()
        toolsMenu.addItem(withTitle: "Accelerate Large Downloads",
                          action: #selector(toggleChunkedDownloads(_:)),
                          keyEquivalent: "")
        let activityParent = toolsMenu.addItem(withTitle: "Tab Activity", action: nil, keyEquivalent: "")
        activityMenu.delegate = self
        toolsMenu.setSubmenu(activityMenu, for: activityParent)
        let watchesParent = toolsMenu.addItem(withTitle: "Watches", action: nil, keyEquivalent: "")
        watchesMenu.delegate = self
        toolsMenu.setSubmenu(watchesMenu, for: watchesParent)
        let compareParent = toolsMenu.addItem(withTitle: "Compare", action: nil, keyEquivalent: "")
        compareMenu.delegate = self
        toolsMenu.setSubmenu(compareMenu, for: compareParent)
        toolsMenu.addItem(.separator())
        let passwordsParent = toolsMenu.addItem(withTitle: "Passwords", action: nil, keyEquivalent: "")
        passwordsMenu.delegate = self
        toolsMenu.setSubmenu(passwordsMenu, for: passwordsParent)
        rebuildPasswordsMenu()
        toolsMenu.addItem(.separator())
        let suggestionsParent = toolsMenu.addItem(withTitle: "New Tab Suggestions",
                                                  action: nil, keyEquivalent: "")
        suggestionsMenu.delegate = self
        toolsMenu.setSubmenu(suggestionsMenu, for: suggestionsParent)
        rebuildSuggestionsMenu()
        toolsMenu.addItem(withTitle: "Change New Tab Wallpaper…",
                          action: #selector(chooseWallpaper(_:)),
                          keyEquivalent: "")
        toolsMenu.addItem(withTitle: "Use Default New Tab Background",
                          action: #selector(resetWallpaper(_:)),
                          keyEquivalent: "")

        let windowMenu = addSubmenu("Window", to: main)
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let nextTab = windowMenu.addItem(withTitle: "Show Next Tab",
                                         action: #selector(NSWindow.selectNextTab(_:)),
                                         keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        let previousTab = windowMenu.addItem(withTitle: "Show Previous Tab",
                                             action: #selector(NSWindow.selectPreviousTab(_:)),
                                             keyEquivalent: "\t")
        previousTab.keyEquivalentModifierMask = [.control, .shift]
        let switchMenu = NSMenu(title: "Switch to Tab")
        for number in 1...9 {
            let item = switchMenu.addItem(withTitle: "Tab \(number)",
                                          action: #selector(BrowserWindowController.selectTabByNumber(_:)),
                                          keyEquivalent: "\(number)")
            item.tag = number
        }
        let switchItem = windowMenu.addItem(withTitle: "Switch to Tab", action: nil, keyEquivalent: "")
        windowMenu.setSubmenu(switchMenu, for: switchItem)
        let allTabs = windowMenu.addItem(withTitle: "Show All Tabs",
                                         action: #selector(NSWindow.toggleTabOverview(_:)),
                                         keyEquivalent: "\\")
        allTabs.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(withTitle: "Move Tab to New Window",
                           action: #selector(NSWindow.moveTabToNewWindow(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(withTitle: "Merge All Windows",
                           action: #selector(NSWindow.mergeAllWindows(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)),
                           keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        return main
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setAsDefaultBrowser(_:)):
            if isDefaultBrowser {
                menuItem.title = "Rocket Is Your Default Browser"
                return false
            }
            menuItem.title = "Set Rocket as Default Browser"
            return true
        case #selector(toggleBookmarksBar(_:)):
            let shown = UserDefaults.standard.object(forKey: "ShowBookmarksBar") as? Bool ?? true
            menuItem.title = shown ? "Hide Bookmarks Bar" : "Show Bookmarks Bar"
            return true
        case #selector(toggleAdBlocking(_:)):
            menuItem.state = ContentBlocker.shared.adsEnabled ? .on : .off
            return true
        case #selector(toggleCookieBanners(_:)):
            menuItem.state = ContentBlocker.shared.cookieBannersHidden ? .on : .off
            return true
        case #selector(toggleFingerprintProtection(_:)):
            menuItem.state = PrivacyShield.isEnabled ? .on : .off
            return true
        case #selector(togglePromoBlocking(_:)):
            menuItem.state = PromoBlocker.isEnabled ? .on : .off
            return true
        case #selector(resetWallpaper(_:)):
            return NewTabPage.wallpaperURL != nil
        case #selector(reopenClosedTab(_:)):
            return !closedTabs.isEmpty
        case #selector(reopenLastSession(_:)):
            guard let previousSession, !previousSession.isEmpty else {
                menuItem.title = "Reopen Last Session"
                return false
            }
            let count = previousSession.tabCount
            menuItem.title = "Reopen Last Session (\(count) Tab\(count == 1 ? "" : "s"))"
            return true
        case #selector(toggleSessionRestore(_:)):
            menuItem.state = SessionStore.restoresOnLaunch ? .on : .off
            return true
        case #selector(toggleAgentAccess(_:)):
            menuItem.state = AgentServer.isEnabled ? .on : .off
            return true
        case #selector(toggleSearchSuggestions(_:)):
            menuItem.state = AddressSuggestionProvider.remoteEnabled ? .on : .off
            return true
        case #selector(toggleImageTextSearch(_:)):
            menuItem.state = ImageTextScanner.isEnabled ? .on : .off
            return true
        case #selector(toggleChunkedDownloads(_:)):
            menuItem.state = ChunkedDownload.isEnabled ? .on : .off
            return true
        case #selector(togglePreconnect(_:)):
            menuItem.state = WaypointPreconnect.isEnabled ? .on : .off
            return true
        case #selector(setScanPolicy(_:)):
            let policies: [Int: ScanPolicy] = [0: .off, 1: .riskyOrLarge, 2: .everything]
            menuItem.state = policies[menuItem.tag] == VirusTotal.policy ? .on : .off
            return true
        case #selector(toggleVirusTotalUploads(_:)):
            menuItem.state = VirusTotal.uploadsUnknownFiles ? .on : .off
            return VirusTotal.hasAPIKey
        case #selector(showDownloadsWindow(_:)):
            return frontBrowserController != nil
        case #selector(toggleSuggestions(_:)):
            menuItem.state = SuggestionEngine.shared.isEnabled ? .on : .off
            return true
        case #selector(retrainSuggestions(_:)):
            return SuggestionEngine.shared.isEnabled
        case #selector(excludeCurrentSite(_:)):
            return SuggestionEngine.shared.isEnabled
                && frontBrowserController?.webView.url?.host != nil
        case #selector(lockPasswords(_:)):
            return PasswordStore.shared.isUnlocked
        case #selector(togglePasswordAutofill(_:)):
            menuItem.state = PasswordFlows.autofillEnabled ? .on : .off
            return true
        case #selector(togglePasswordSaving(_:)):
            menuItem.state = PasswordFlows.offersToSave ? .on : .off
            return true
        case #selector(togglePasswordSubmit(_:)):
            menuItem.state = PasswordFlows.submitsAfterFill ? .on : .off
            return PasswordFlows.autofillEnabled
        case #selector(setPasswordsLockAfter(_:)):
            menuItem.state = menuItem.tag == PasswordFlows.lockAfterSeconds ? .on : .off
            return true
        case #selector(changeRecoveryKey(_:)), #selector(exportPasswords(_:)):
            return PasswordStore.shared.isSetUp
        case #selector(restorePasswords(_:)):
            return PasswordStore.shared.needsRestore
        default:
            return true
        }
    }

}
