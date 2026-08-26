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
    /// Recently closed tabs, newest last — the ⇧⌘T stack.
    private var closedTabs: [(url: URL, title: String?)] = []

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
        openNewWindow(url: nil)
        // Don't steal focus when launched hidden (e.g. `open -gj` for background testing).
        if !NSApp.isHidden {
            NSApp.activate()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        SuggestionEngine.shared.retrainIfDue { [weak self] trained in
            if trained { self?.reloadNewTabPages() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HistoryStore.shared.flush()
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

    func register(_ controller: BrowserWindowController) {
        controllers.append(controller)
    }

    func unregister(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
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

    @objc func toggleFingerprintProtection(_ sender: Any?) {
        PrivacyShield.isEnabled.toggle()
        ContentBlocker.shared.applyToAllWebViews?()
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
        historyMenu.addItem(.separator())
        historyMenu.addItem(withTitle: "Home",
                            action: #selector(BrowserWindowController.goHome(_:)),
                            keyEquivalent: "H")

        let bookmarksItem = NSMenuItem(title: "Bookmarks", action: nil, keyEquivalent: "")
        bookmarksItem.submenu = bookmarksMenu
        bookmarksMenu.delegate = self
        main.addItem(bookmarksItem)
        rebuildBookmarksMenu()

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
        toolsMenu.addItem(withTitle: "Search Suggestions",
                          action: #selector(toggleSearchSuggestions(_:)),
                          keyEquivalent: "")
        toolsMenu.addItem(.separator())
        let downloadsItem = toolsMenu.addItem(withTitle: "Show Downloads",
                                              action: #selector(showDownloadsWindow(_:)),
                                              keyEquivalent: "l")
        downloadsItem.keyEquivalentModifierMask = [.command, .option]
        let securityParent = toolsMenu.addItem(withTitle: "Download Scanning", action: nil, keyEquivalent: "")
        securityMenu.delegate = self
        toolsMenu.setSubmenu(securityMenu, for: securityParent)
        rebuildSecurityMenu()
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
        case #selector(resetWallpaper(_:)):
            return NewTabPage.wallpaperURL != nil
        case #selector(reopenClosedTab(_:)):
            return !closedTabs.isEmpty
        case #selector(toggleSearchSuggestions(_:)):
            menuItem.state = AddressSuggestionProvider.remoteEnabled ? .on : .off
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
        default:
            return true
        }
    }

}
