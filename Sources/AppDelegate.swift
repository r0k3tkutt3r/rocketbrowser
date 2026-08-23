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

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = buildMainMenu()
        NSApp.applicationIconImage = Self.makeAppIcon()

        IncognitoSession.purgeLeftoverStores()

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

    /// Cmd+T falls through to here when no browser window is open.
    @objc func newWindowForTab(_ sender: Any?) {
        openNewWindow(url: nil)
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
        }
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
        viewMenu.addItem(withTitle: "Block Ads and Trackers",
                         action: #selector(toggleAdBlocking(_:)),
                         keyEquivalent: "")
        viewMenu.addItem(withTitle: "Hide Cookie Banners",
                         action: #selector(toggleCookieBanners(_:)),
                         keyEquivalent: "")
        viewMenu.addItem(withTitle: "Fingerprinting Protection",
                         action: #selector(toggleFingerprintProtection(_:)),
                         keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Change New Tab Wallpaper…",
                         action: #selector(chooseWallpaper(_:)),
                         keyEquivalent: "")
        viewMenu.addItem(withTitle: "Use Default New Tab Background",
                         action: #selector(resetWallpaper(_:)),
                         keyEquivalent: "")
        let suggestionsParent = viewMenu.addItem(withTitle: "New Tab Suggestions",
                                                 action: nil, keyEquivalent: "")
        suggestionsMenu.delegate = self
        viewMenu.setSubmenu(suggestionsMenu, for: suggestionsParent)
        rebuildSuggestionsMenu()
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
        historyMenu.addItem(.separator())
        historyMenu.addItem(withTitle: "Home",
                            action: #selector(BrowserWindowController.goHome(_:)),
                            keyEquivalent: "H")

        let bookmarksItem = NSMenuItem(title: "Bookmarks", action: nil, keyEquivalent: "")
        bookmarksItem.submenu = bookmarksMenu
        bookmarksMenu.delegate = self
        main.addItem(bookmarksItem)
        rebuildBookmarksMenu()

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

    // MARK: - App icon

    private static func makeAppIcon() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let inset = rect.insetBy(dx: 44, dy: 44)
            let path = NSBezierPath(roundedRect: inset, xRadius: 116, yRadius: 116)
            NSGradient(colors: [
                NSColor(calibratedRed: 0.28, green: 0.16, blue: 0.65, alpha: 1),
                NSColor(calibratedRed: 0.63, green: 0.27, blue: 0.90, alpha: 1),
            ])?.draw(in: path, angle: 90)
            let emoji = NSAttributedString(string: "🚀", attributes: [.font: NSFont.systemFont(ofSize: 264)])
            let size = emoji.size()
            emoji.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }
}
