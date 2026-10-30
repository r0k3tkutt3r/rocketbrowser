import UIKit
import WebKit

/// The one screen: the current tab's page, with Safari's bottom bar floating over it —
/// back/forward, the address bar and share/bookmarks/⋯ in a single glass row. Tabs
/// are plain objects whose web views are swapped in and out of `webHost`; a phone has
/// no windows to hang them on, unlike the Mac, where a tab is a window.
final class BrowserViewController: UIViewController {

    private(set) var tabs: [Tab] = []
    private(set) var currentTab: Tab?

    /// The bottom row. Slides away as you scroll down and back as you scroll up
    /// (`setChromeHidden`); ⋯ ▸ Hide Buttons folds it to the address bar and ⋯.
    private let chrome = UIStackView()
    private let navGroup = BrowserViewController.glass(interactive: false)
    private let actionGroup = BrowserViewController.glass(interactive: false)
    private let addressPill = BrowserViewController.glass(interactive: true)
    private let urlField = UITextField()
    private let cancelButton = UIButton(type: .system)
    private let reloadButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let backButton = BrowserViewController.barButton("chevron.backward", label: "Back")
    private let forwardButton = BrowserViewController.barButton("chevron.forward", label: "Forward")
    private let shareButton = BrowserViewController.barButton("square.and.arrow.up", label: "Share")
    private let bookmarksButton = BrowserViewController.barButton("book", label: "Bookmarks")
    private let menuButton = BrowserViewController.barButton("ellipsis", label: "More")
    /// What is left of the chrome while scrolled away: the site's name, tap to return.
    private let compactPill = BrowserViewController.glass(interactive: false)
    private let compactLabel = UILabel()
    /// Colours the status bar area with the page, as Safari does with bottom bars.
    private let statusBacking = UIView()
    /// Hosts the current web view by autoresizing, never constraints: element
    /// fullscreen re-parents the web view and sizes it by frame alone (see CLAUDE.md).
    private let webHost = UIView()
    private let suggestionsTable = UITableView(frame: .zero, style: .plain)
    /// The address bar follows the keyboard only while it is the thing being typed in;
    /// a page's own text field gets the keyboard over the chrome instead.
    private var chromeAboveKeyboard: NSLayoutConstraint!
    private var chromeAboveSafeArea: NSLayoutConstraint!

    private var chromeHidden = false
    private var scrollRun: CGFloat = 0
    private var lastScrollY: CGFloat = 0
    private var statusBarStyle: UIStatusBarStyle = .default
    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }

    /// Address-bar drags: sideways pages between tabs, upwards opens the overview.
    private enum BarDrag { case sideways, upwards }
    private var barDrag: BarDrag?
    private var dragStartOffset: CGFloat = 0
    /// The neighbouring tab's web view (or a blank stand-in for a new tab) parked
    /// beside the page while the bar is dragged sideways.
    private var peekView: UIView?
    private var peekTab: Tab?
    private var peekForward = false
    private var settle: UIViewPropertyAnimator?
    private let overviewTransition = TabOverviewTransition()
    /// The page's corners while it is lifted toward the overview, before scaling.
    private let liftCorner: CGFloat = 48

    private var buttonsCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: "BottomButtonsCollapsed") }
        set { UserDefaults.standard.set(newValue, forKey: "BottomButtonsCollapsed") }
    }

    private var observations: [NSKeyValueObservation] = []
    private var suggestions: [AddressSuggestion] = []
    private lazy var completer = AddressCompleter(
        privateSearch: currentTab?.isPrivate ?? false,
        editingText: { [weak self] in
            guard let self, self.urlField.isFirstResponder else { return nil }
            return self.urlField.text
        },
        render: { [weak self] in self?.showSuggestions($0) })

    /// Liquid Glass where the system has it (iOS 26), a material blur before that.
    /// Every surface in the row is a capsule 48 pt tall.
    private static func glass(interactive: Bool) -> UIVisualEffectView {
        if #available(iOS 26, *) {
            let effect = UIGlassEffect()
            effect.isInteractive = interactive
            let view = UIVisualEffectView(effect: effect)
            view.cornerConfiguration = .capsule()
            return view
        }
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        view.layer.cornerRadius = 24
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }

    private static func barButton(_ symbol: String, label: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol,
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    /// Buttons that share one glass capsule, the way iOS groups toolbar items.
    private static func fill(_ group: UIVisualEffectView, with buttons: [UIButton]) {
        let stack = UIStackView(arrangedSubviews: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        group.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: group.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: group.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: group.contentView.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: group.contentView.trailingAnchor, constant: -2),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureAddressBar()
        configureButtons()
        configureCompactPill()
        suggestionsTable.dataSource = self
        suggestionsTable.delegate = self
        suggestionsTable.keyboardDismissMode = .onDrag
        suggestionsTable.isHidden = true

        for view in [navGroup, addressPill, actionGroup, cancelButton] as [UIView] {
            chrome.addArrangedSubview(view)
        }
        chrome.spacing = 6
        chrome.alignment = .center
        chrome.isLayoutMarginsRelativeArrangement = true
        chrome.directionalLayoutMargins = .init(top: 0, leading: 10, bottom: 0, trailing: 10)
        applyButtonsCollapsed()

        for subview in [webHost, statusBacking, suggestionsTable, compactPill, chrome] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let safe = view.safeAreaLayoutGuide
        chromeAboveKeyboard = chrome.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8)
        chromeAboveSafeArea = chrome.bottomAnchor.constraint(equalTo: safe.bottomAnchor)
        NSLayoutConstraint.activate([
            statusBacking.topAnchor.constraint(equalTo: view.topAnchor),
            statusBacking.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBacking.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBacking.bottomAnchor.constraint(equalTo: safe.topAnchor),
            // To the screen's bottom edge: the chrome floats over the page (applyBottomInset).
            webHost.topAnchor.constraint(equalTo: safe.topAnchor),
            webHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            suggestionsTable.topAnchor.constraint(equalTo: safe.topAnchor),
            suggestionsTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            suggestionsTable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            suggestionsTable.bottomAnchor.constraint(equalTo: chrome.topAnchor, constant: -6),
            chrome.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            chromeAboveSafeArea,
            addressPill.heightAnchor.constraint(equalToConstant: 48),
            navGroup.heightAnchor.constraint(equalToConstant: 48),
            actionGroup.heightAnchor.constraint(equalToConstant: 48),
            compactPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            compactPill.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            compactPill.heightAnchor.constraint(equalToConstant: 32),
            compactPill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),
        ])

        Downloads.shared.onFinish = { [weak self] file in self?.downloadFinished(file) }
        Downloads.shared.onFailure = { [weak self] name, error in
            let alert = UIAlertController(title: "Couldn’t download \(name)",
                                          message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.presentAlert(alert)
        }
    }

    private func configureAddressBar() {
        urlField.placeholder = "Search or enter website"
        urlField.font = .preferredFont(forTextStyle: .subheadline)
        urlField.adjustsFontForContentSizeCategory = true
        // The bar shares its row with five buttons; a long address shrinks a little
        // before it truncates, so the site's name stays readable.
        urlField.adjustsFontSizeToFitWidth = true
        urlField.minimumFontSize = 12
        urlField.textAlignment = .center
        urlField.keyboardType = .webSearch
        urlField.returnKeyType = .go
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.spellCheckingType = .no
        urlField.textContentType = .URL
        urlField.clearButtonMode = .whileEditing
        urlField.leftViewMode = .always
        urlField.delegate = self
        urlField.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.completer.update(for: self.urlField.text ?? "")
        }, for: .editingChanged)
        // The bar's swipes, for anyone who cannot make them.
        urlField.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Show All Tabs") { [weak self] _ in self?.showTabs(); return true },
            UIAccessibilityCustomAction(name: "Next Tab") { [weak self] _ in self?.stepTab(forward: true) ?? false },
            UIAccessibilityCustomAction(name: "Previous Tab") { [weak self] _ in self?.stepTab(forward: false) ?? false },
        ]

        reloadButton.frame = CGRect(x: 0, y: 0, width: 34, height: 44)
        reloadButton.tintColor = .label
        reloadButton.accessibilityLabel = "Reload"
        reloadButton.addAction(UIAction { [weak self] _ in
            guard let webView = self?.currentTab?.webView else { return }
            if webView.isLoading { webView.stopLoading() } else { webView.reload() }
        }, for: .touchUpInside)
        urlField.rightView = reloadButton
        // Toggled by hand in the delegate: .unlessEditing still shows it while an
        // empty field is being edited.
        urlField.rightViewMode = .always

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.isHidden = true
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.addAction(UIAction { [weak self] _ in
            self?.urlField.resignFirstResponder()
        }, for: .touchUpInside)

        progressView.trackTintColor = .clear
        progressView.isHidden = true
        for subview in [urlField, progressView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addressPill.contentView.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            urlField.topAnchor.constraint(equalTo: addressPill.contentView.topAnchor),
            urlField.bottomAnchor.constraint(equalTo: addressPill.contentView.bottomAnchor),
            urlField.leadingAnchor.constraint(equalTo: addressPill.contentView.leadingAnchor, constant: 4),
            urlField.trailingAnchor.constraint(equalTo: addressPill.contentView.trailingAnchor, constant: -2),
            progressView.leadingAnchor.constraint(equalTo: addressPill.contentView.leadingAnchor, constant: 18),
            progressView.trailingAnchor.constraint(equalTo: addressPill.contentView.trailingAnchor, constant: -18),
            progressView.bottomAnchor.constraint(equalTo: addressPill.contentView.bottomAnchor, constant: -3),
        ])
        // The pill gives way to the buttons, never the other way round.
        addressPill.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressPill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Safari's gestures: drag the bar sideways to page between tabs, up for all tabs.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragAddressBar(_:)))
        drag.delegate = self
        addressPill.addGestureRecognizer(drag)
    }

    private func configureButtons() {
        backButton.addAction(UIAction { [weak self] _ in self?.currentTab?.webView.goBack() }, for: .primaryActionTriggered)
        forwardButton.addAction(UIAction { [weak self] _ in self?.currentTab?.webView.goForward() }, for: .primaryActionTriggered)
        shareButton.addAction(UIAction { [weak self] _ in self?.share() }, for: .primaryActionTriggered)
        bookmarksButton.addAction(UIAction { [weak self] _ in self?.showBookmarks() }, for: .primaryActionTriggered)
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuElements() ?? [])
            },
        ])
        menuButton.showsMenuAsPrimaryAction = true
        Self.fill(navGroup, with: [backButton, forwardButton])
        Self.fill(actionGroup, with: [shareButton, bookmarksButton, menuButton])
    }

    private func configureCompactPill() {
        compactLabel.font = .preferredFont(forTextStyle: .footnote).withTraits(.traitBold)
        compactLabel.textAlignment = .center
        compactLabel.translatesAutoresizingMaskIntoConstraints = false
        compactPill.contentView.addSubview(compactLabel)
        NSLayoutConstraint.activate([
            compactLabel.centerYAnchor.constraint(equalTo: compactPill.contentView.centerYAnchor),
            compactLabel.leadingAnchor.constraint(equalTo: compactPill.contentView.leadingAnchor, constant: 16),
            compactLabel.trailingAnchor.constraint(equalTo: compactPill.contentView.trailingAnchor, constant: -16),
        ])
        compactPill.alpha = 0
        compactPill.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showChrome)))
    }

    // MARK: - Tabs

    func restoreSession() {
        for saved in SessionStore.shared.load()?.windows.flatMap(\.tabs) ?? [] {
            guard let url = URL(string: saved.url) else { continue }
            add(Tab(restoring: url, title: saved.title), after: nil)
        }
        if let last = tabs.last {
            select(last)
        } else {
            openTab(nil, incognitoSession: nil)
        }
    }

    @discardableResult
    func openTab(_ url: URL?, incognitoSession: IncognitoSession?, select shouldSelect: Bool = true) -> Tab {
        let tab = Tab(incognitoSession: incognitoSession)
        add(tab, after: currentTab)
        if let url {
            tab.load(url)
        } else {
            tab.openNewTabPage()
        }
        if shouldSelect { select(tab) }
        return tab
    }

    /// Every incognito tab shares one session; it ends with the last of them.
    /// "New Tab" stays in the mode you are in, as in Safari; the way out of incognito
    /// is the switch in the tab overview, which closes every private tab.
    func newTab(private isPrivate: Bool, focus: Bool = true) {
        let open = { [self] in
            let session = isPrivate ? (tabs.first(where: \.isPrivate)?.incognitoSession ?? IncognitoSession()) : nil
            openTab(nil, incognitoSession: session)
            if focus { focusAddressBar() }
        }
        // Crossing between normal and incognito passes through black, as it does in
        // the overview; the overview itself does its own fading.
        if isPrivate != (currentTab?.isPrivate ?? false), presentedViewController == nil, let window = view.window {
            window.fadeThroughBlack(midpoint: open)
        } else {
            open()
        }
    }

    func focusAddressBar() {
        urlField.becomeFirstResponder()
    }

    func openPopup(configuration: WKWebViewConfiguration, from opener: Tab) -> WKWebView {
        let tab = Tab(configuration: configuration, incognitoSession: opener.incognitoSession)
        add(tab, after: opener)
        select(tab)
        return tab.webView
    }

    private func add(_ tab: Tab, after anchor: Tab?) {
        tab.browser = self
        if let anchor, let index = tabs.firstIndex(where: { $0 === anchor }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
    }

    func select(_ tab: Tab) {
        guard tab !== currentTab else { return }
        if urlField.isFirstResponder { urlField.resignFirstResponder() }
        currentTab?.captureSnapshot()
        detachCurrentTab()
        currentTab = tab

        let webView = tab.webView
        webView.frame = webHost.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webHost.addSubview(webView)
        setChromeHidden(false, animated: false)
        lastScrollY = webView.scrollView.contentOffset.y
        scrollRun = 0
        applyBottomInset()
        tab.loadIfRestored()
        tab.resumeActiveTiming()

        completer.privateSearch = tab.isPrivate
        // Incognito is always dark, as on the Mac. Set on the controller, not its view,
        // so the status bar follows.
        overrideUserInterfaceStyle = tab.isPrivate ? .dark : .unspecified
        urlField.keyboardAppearance = tab.isPrivate ? .dark : .default
        urlField.placeholder = tab.isPrivate ? "Search privately" : "Search or enter website"
        urlField.leftView = tab.isPrivate ? Self.privateBadge() : UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))

        observations = [
            webView.observe(\.url) { [weak self] _, _ in
                // A new page brings the bars back, as in Safari.
                self?.setChromeHidden(false)
                self?.updateChrome()
            },
            webView.scrollView.observe(\.contentOffset) { [weak self] scrollView, _ in
                self?.pageScrolled(scrollView)
            },
            webView.observe(\.themeColor) { [weak self] _, _ in self?.updateStatusBacking() },
            webView.observe(\.underPageBackgroundColor) { [weak self] _, _ in self?.updateStatusBacking() },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in self?.updateProgress() },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.updateChrome() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.updateChrome() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.updateChrome() },
        ]
        updateChrome()
        updateStatusBacking()
        scheduleSessionSave()
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: index)
        let wasCurrent = tab === currentTab
        if wasCurrent { detachCurrentTab() }
        tab.close()
        if wasCurrent {
            // The tab to the left in the same mode — for a popup, the page that opened
            // it. Running out of private tabs drops back to normal browsing.
            let sameMode = tabs.enumerated().filter { $0.element.isPrivate == tab.isPrivate }
            if let neighbor = sameMode.last(where: { $0.offset < index }) ?? sameMode.first {
                select(neighbor.element)
            } else {
                selectNormalTab()
            }
        }
        scheduleSessionSave()
    }

    /// Leaving incognito ends it: every private tab closes at once, and with the last
    /// one the session's data store is wiped.
    func closePrivateTabs() {
        let closing = tabs.filter(\.isPrivate)
        guard !closing.isEmpty else { return }
        let wasPrivate = currentTab?.isPrivate ?? false
        tabs.removeAll(where: \.isPrivate)
        if wasPrivate { detachCurrentTab() }
        closing.forEach { $0.close() }
        if wasPrivate { selectNormalTab() }
    }

    private func selectNormalTab() {
        if let normal = tabs.last(where: { !$0.isPrivate }) {
            select(normal)
        } else {
            openTab(nil, incognitoSession: nil)
        }
    }

    private func detachCurrentTab() {
        currentTab?.pauseActiveTiming()
        currentTab?.webView.removeFromSuperview()
        observations = []
        currentTab = nil
    }

    func isFrontmost(_ tab: Tab) -> Bool {
        tab === currentTab && view.window?.windowScene?.activationState == .foregroundActive
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyBottomInset()
    }

    /// The page runs under the floating chrome and the home indicator, so the scroll
    /// view is inset by exactly that overlap: the last line of a page scrolls clear of
    /// the buttons. WebKit also reads this inset as the obscured area, which keeps a
    /// page's fixed footer above the chrome rather than under it. Measured from centre
    /// and bounds, because the frame of the chrome moves with its hide transform.
    private func applyBottomInset() {
        guard let scrollView = currentTab?.webView.scrollView, !urlField.isFirstResponder else { return }
        let coverTop = chromeHidden
            ? compactPill.center.y - compactPill.bounds.height / 2
            : chrome.center.y - chrome.bounds.height / 2
        let overlap = max(0, webHost.frame.maxY - coverTop)
        scrollView.contentInsetAdjustmentBehavior = .never
        if scrollView.contentInset.bottom != overlap {
            scrollView.contentInset.bottom = overlap
            scrollView.verticalScrollIndicatorInsets.bottom = overlap
        }
    }

    private static func privateBadge() -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "eyeglasses"))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .center
        icon.frame = CGRect(x: 0, y: 0, width: 36, height: 30)
        return icon
    }

    // MARK: - Session and settings

    func scheduleSessionSave() {
        SessionStore.shared.scheduleSave { [weak self] in
            self?.sessionSnapshot() ?? SessionSnapshot.build(from: [])
        }
    }

    /// One "window" holding every tab, in order. `SessionSnapshot` drops incognito
    /// tabs and start pages, exactly as it does for the Mac.
    func sessionSnapshot() -> SavedSession {
        SessionSnapshot.build(from: tabs.map { tab in
            SessionSnapshot.Entry(url: tab.sessionURL?.absoluteString ?? "", title: tab.title, groupKey: 0,
                                  isPrivate: tab.isPrivate, isNewTabPage: NewTabPage.isInternalURL(tab.sessionURL))
        })
    }

    func reapplyContentRules() {
        for tab in tabs {
            ContentBlocker.shared.apply(to: tab.webView, isIncognito: tab.isPrivate)
            if tab.webView.url != nil { tab.webView.reload() }
        }
    }

    func reloadNewTabPages() {
        for tab in tabs where NewTabPage.isNewTabURL(tab.webView.url) {
            NewTabPage.open(in: tab.webView)
        }
    }

    // MARK: - Chrome

    private func updateChrome() {
        guard let webView = currentTab?.webView else { return }
        if !urlField.isFirstResponder {
            // Unfocused, the field shows the simplified form; editing gets the real URL.
            urlField.text = NewTabPage.isInternalURL(webView.url) ? "" : addressText(for: webView.url)
        }
        reloadButton.setImage(UIImage(systemName: webView.isLoading ? "xmark" : "arrow.clockwise"), for: .normal)
        compactLabel.text = NewTabPage.isInternalURL(webView.url)
            ? (currentTab?.isPrivate == true ? "Incognito" : "New Tab")
            : URLDisplay.displayString(for: Self.siteURL(of: webView.url))
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        shareButton.isEnabled = !NewTabPage.isInternalURL(webView.url)
        updateProgress()
    }

    /// The one-row bar is narrow, so a search result shows its engine's name like
    /// any other page; folded, the bar has room for the query too. Either way the host
    /// keeps its subdomains — `URLDisplay`'s rule against the phishing shortcut.
    private func addressText(for url: URL?) -> String {
        guard !buttonsCollapsed, let url, URLDisplay.searchQuery(from: url) != nil else {
            return URLDisplay.displayString(for: url)
        }
        return URLDisplay.displayString(for: Self.siteURL(of: url))
    }

    private static func siteURL(of url: URL?) -> URL? {
        url?.host.flatMap { URL(string: "https://\($0)") }
    }

    private func updateProgress() {
        guard let webView = currentTab?.webView else { return }
        progressView.isHidden = !webView.isLoading
        progressView.setProgress(Float(webView.estimatedProgress), animated: webView.isLoading)
    }

    private func load(_ url: URL) {
        currentTab?.load(url)
    }

    private func showSuggestions(_ list: [AddressSuggestion]) {
        suggestions = urlField.isFirstResponder ? list : []
        suggestionsTable.isHidden = suggestions.isEmpty
        suggestionsTable.reloadData()
    }

    /// Presents over whatever is already up. Refuses (returns false) for a tab that is
    /// not on screen, or when an alert is already showing, so a page cannot stack them.
    @discardableResult
    func presentAlert(_ alert: UIAlertController, from tab: Tab? = nil) -> Bool {
        if let tab, tab !== currentTab { return false }
        var top: UIViewController = self
        while let next = top.presentedViewController { top = next }
        guard !(top is UIAlertController), !top.isBeingDismissed else { return false }
        top.present(alert, animated: true)
        return true
    }

    // MARK: - Actions

    private func menuElements() -> [UIMenuElement] {
        let tab = currentTab
        let url = tab?.webView.url
        let onPage = url != nil && !NewTabPage.isInternalURL(url)
        let bookmarked = onPage && BookmarkStore.shared.containsBookmark(url: url!.absoluteString)
        let enabledOnPage: UIMenuElement.Attributes = onPage ? [] : .disabled

        // Nearest the thumb: fold or unfold the row, and — while it is folded — the
        // buttons it hid.
        let collapsed = buttonsCollapsed
        var rowItems: [UIMenuElement] = [
            UIAction(title: collapsed ? "Show Buttons" : "Hide Buttons",
                     image: UIImage(systemName: collapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")) {
                [weak self] _ in self?.setButtonsCollapsed(!collapsed)
            },
        ]
        if collapsed {
            rowItems += [
                UIAction(title: "Back", image: UIImage(systemName: "chevron.backward"),
                         attributes: tab?.webView.canGoBack == true ? [] : .disabled) { _ in tab?.webView.goBack() },
                UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up"),
                         attributes: enabledOnPage) { [weak self] _ in self?.share() },
                UIAction(title: "Bookmarks", image: UIImage(systemName: "book")) { [weak self] _ in
                    self?.showBookmarks()
                },
            ]
        }
        let folded = [UIMenu(options: .displayInline, children: rowItems)]
        let page = UIMenu(options: .displayInline, children: [
            UIAction(title: bookmarked ? "Remove Bookmark" : "Add Bookmark",
                     image: UIImage(systemName: bookmarked ? "star.slash" : "star"),
                     attributes: enabledOnPage) { [weak self] _ in self?.toggleBookmark() },
            UIAction(title: "Find on Page", image: UIImage(systemName: "doc.text.magnifyingglass"),
                     attributes: enabledOnPage) { _ in
                tab?.webView.findInteraction?.presentFindNavigator(showingReplace: false)
            },
        ])
        let browsing = UIMenu(options: .displayInline, children: newTabActions() + [
            // Also a swipe up on the address bar; here for anyone who has not found it.
            UIAction(title: "All Tabs", image: UIImage(systemName: "square.on.square")) { [weak self] _ in
                self?.showTabs()
            },
            UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                if let tab = self?.currentTab { self?.close(tab) }
            },
            UIAction(title: "History", image: UIImage(systemName: "clock")) { [weak self] _ in
                self?.showHistory()
            },
            UIAction(title: "Downloads", image: UIImage(systemName: "arrow.down.circle")) { _ in
                // Opens the Files app on Rocket's own Downloads folder.
                try? FileManager.default.createDirectory(at: Downloads.directory, withIntermediateDirectories: true)
                if let files = URL(string: "shareddocuments://" + Downloads.directory.path) {
                    UIApplication.shared.open(files)
                }
            },
        ])
        // The iOS counterpart of the Mac's Tools menu: how Rocket itself behaves.
        let blocker = ContentBlocker.shared
        let settings = UIMenu(title: "Settings", image: UIImage(systemName: "gearshape"), children: [
            toggle("Block Ads & Trackers", blocker.adsEnabled) { blocker.adsEnabled = $0 },
            toggle("Hide Cookie Banners", blocker.cookieBannersHidden) { blocker.cookieBannersHidden = $0 },
            toggle("Fingerprinting Protection", PrivacyShield.isEnabled) {
                PrivacyShield.isEnabled = $0
                blocker.applyToAllWebViews?()
            },
            toggle("Hide Browser Promos", PromoBlocker.isEnabled) {
                PromoBlocker.isEnabled = $0
                blocker.applyToAllWebViews?()
            },
            toggle("Preconnect Sign-In Hops", WaypointPreconnect.isEnabled) {
                WaypointPreconnect.isEnabled = $0
                blocker.applyToAllWebViews?()
            },
            toggle("Search Suggestions", AddressSuggestionProvider.remoteEnabled) {
                AddressSuggestionProvider.remoteEnabled = $0
            },
            // Also the history gate, exactly as on the Mac: off means nothing is recorded.
            toggle("New Tab Suggestions", SuggestionEngine.shared.isEnabled) { [weak self] isOn in
                SuggestionEngine.shared.isEnabled = isOn
                self?.reloadNewTabPages()
            },
        ])
        return folded + [page, browsing, settings]
    }

    /// New Tab opens in the current mode; New Incognito Tab is only offered outside it.
    private func newTabActions() -> [UIAction] {
        let inPrivate = currentTab?.isPrivate ?? false
        var actions = [UIAction(title: "New Tab", image: UIImage(systemName: "plus.square")) { [weak self] _ in
            self?.newTab(private: inPrivate)
        }]
        if !inPrivate {
            actions.append(UIAction(title: "New Incognito Tab", image: UIImage(systemName: "eyeglasses")) { [weak self] _ in
                self?.newTab(private: true)
            })
        }
        return actions
    }

    private func toggle(_ title: String, _ isOn: Bool, _ set: @escaping (Bool) -> Void) -> UIAction {
        UIAction(title: title, state: isOn ? .on : .off) { _ in set(!isOn) }
    }

    private func toggleBookmark() {
        guard let webView = currentTab?.webView, let url = webView.url?.absoluteString else { return }
        let store = BookmarkStore.shared
        if store.containsBookmark(url: url) {
            store.removeBookmark(url: url)
        } else {
            let title = webView.title ?? ""
            store.addBookmark(Bookmark(title: title.isEmpty ? url : title, url: url))
        }
    }

    private func share() {
        guard let url = currentTab?.webView.url, !NewTabPage.isInternalURL(url) else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = buttonsCollapsed ? menuButton : shareButton
        present(sheet, animated: true)
    }

    private func downloadFinished(_ file: URL) {
        let alert = UIAlertController(title: "Downloaded \(file.lastPathComponent)",
                                      message: "Saved in Files ▸ On My iPhone ▸ Rocket ▸ Downloads.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Share…", style: .default) { [weak self] _ in
            guard let self else { return }
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = self.chrome
            self.present(sheet, animated: true)
        })
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        presentAlert(alert)
    }

    private func presentSheet(_ root: UIViewController) {
        let navigation = UINavigationController(rootViewController: root)
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        // Private tabs keep their dark chrome in the sheets they open.
        navigation.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        present(navigation, animated: true)
    }

    private func openFromSheet(_ url: URL) {
        dismiss(animated: true)
        load(url)
    }

    private func showBookmarks() {
        presentSheet(BookmarksViewController(folderID: nil) { [weak self] in self?.openFromSheet($0) })
    }

    private func showHistory() {
        presentSheet(HistoryViewController { [weak self] in self?.openFromSheet($0) })
    }

    /// From the menu or VoiceOver: the same flight into the grid, starting from the
    /// page where it sits. The page is photographed first so its card is current.
    private func showTabs() {
        urlField.resignFirstResponder()
        if let tab = currentTab {
            tab.captureSnapshot { [weak self] in self?.presentOverview() }
        } else {
            presentOverview()
        }
    }

    private func presentOverview(releaseVelocity: CGFloat = 0) {
        guard presentedViewController == nil else { return }
        urlField.resignFirstResponder()
        let overview = TabsViewController(browser: self)
        overview.modalPresentationStyle = .fullScreen
        overview.transitioningDelegate = overviewTransition
        overviewTransition.releaseVelocity = releaseVelocity
        present(overview, animated: true)
    }

    // MARK: Page as a card (used by TabOverviewTransition)

    /// Turns the page into a card over the overview's backdrop: the bar goes at once,
    /// as Safari's does the moment the finger starts upward.
    func enterLiftedState() {
        view.backgroundColor = .systemGroupedBackground
        webHost.clipsToBounds = true
        webHost.layer.cornerCurve = .continuous
        statusBarStyle = .default
        setNeedsStatusBarAppearanceUpdate()
        UIView.animate(withDuration: 0.08) {
            self.chrome.alpha = 0
            self.compactPill.alpha = 0
            self.statusBacking.alpha = 0
            self.webHost.layer.cornerRadius = self.liftCorner
        }
    }

    func leaveLiftedState() {
        webHost.transform = .identity
        webHost.isHidden = false
        webHost.layer.cornerRadius = 0
        webHost.clipsToBounds = false
        view.backgroundColor = .systemBackground
        chrome.alpha = chromeHidden ? 0 : 1
        compactPill.alpha = chromeHidden ? 1 : 0
        statusBacking.alpha = 1
        addressPill.transform = .identity
        updateStatusBacking()
    }

    /// Where the page is on screen right now, lifted or not, in `space`'s coordinates.
    func pageFrame(in space: UIView) -> CGRect {
        webHost.convert(webHost.bounds, to: space)
    }

    /// The page's on-screen corner radius: its lifted radius, shrunk with it.
    var liftedCornerRadius: CGFloat {
        webHost.layer.cornerRadius * webHost.transform.a
    }

    func pageSnapshot() -> UIView? {
        webHost.snapshotView(afterScreenUpdates: false)
    }

    func hidePage() {
        webHost.isHidden = true
    }
}

// MARK: - Address field

extension BrowserViewController: UITextFieldDelegate {

    func textFieldDidBeginEditing(_ textField: UITextField) {
        let url = currentTab?.webView.url
        textField.text = NewTabPage.isInternalURL(url) ? "" : url?.absoluteString
        textField.textAlignment = .natural
        textField.rightViewMode = .never
        setChromeHidden(false, animated: false)
        // Up onto the keyboard, the whole width to itself, as in Safari.
        chromeAboveSafeArea.isActive = false
        chromeAboveKeyboard.isActive = true
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.applyButtonsCollapsed()
            self.chrome.layoutIfNeeded()
        }
        // Selecting inside didBegin is overridden by the tap that focused the field.
        DispatchQueue.main.async { textField.selectAll(nil) }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        textField.textAlignment = .center
        textField.rightViewMode = .always
        chromeAboveKeyboard.isActive = false
        chromeAboveSafeArea.isActive = true
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.applyButtonsCollapsed()
            self.view.layoutIfNeeded()
        }
        showSuggestions([])
        updateChrome()
        applyBottomInset()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let url = URLResolver.resolve(textField.text ?? "", privateSearch: currentTab?.isPrivate ?? false) {
            load(url)
        }
        textField.resignFirstResponder()
        return true
    }
}

// MARK: - Suggestions list

extension BrowserViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        suggestions.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "suggestion")
            ?? UITableViewCell(style: .default, reuseIdentifier: "suggestion")
        let suggestion = suggestions[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.image = UIImage(systemName: suggestion.symbolName)
        content.imageProperties.tintColor = .secondaryLabel
        content.text = suggestion.title
        content.secondaryText = suggestion.subtitle
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let url = suggestions[indexPath.row].url
        urlField.resignFirstResponder()
        load(url)
    }
}

// MARK: - Bottom bar behaviour

extension BrowserViewController: UIGestureRecognizerDelegate {

    /// Scrolling down sends the chrome away; scrolling up, or reaching the top,
    /// brings it back. Only the reader's own drags count — a page scrolling itself
    /// never moves the bars — and a short run in one direction is needed first, so a
    /// jittery thumb does not flicker them.
    private func pageScrolled(_ scrollView: UIScrollView) {
        let y = scrollView.contentOffset.y
        let delta = y - lastScrollY
        lastScrollY = y
        guard scrollView.isDragging || scrollView.isDecelerating, delta != 0 else { return }
        if (delta > 0) != (scrollRun > 0) { scrollRun = 0 }
        scrollRun += delta
        if y <= -scrollView.adjustedContentInset.top + 1 {
            setChromeHidden(false)
        } else if scrollRun > 40 {
            setChromeHidden(true)
        } else if scrollRun < -40 {
            setChromeHidden(false)
        }
    }

    @objc private func showChrome() {
        setChromeHidden(false)
    }

    private func setChromeHidden(_ hidden: Bool, animated: Bool = true) {
        guard hidden != chromeHidden, !(hidden && urlField.isFirstResponder) else { return }
        chromeHidden = hidden
        let changes = {
            let drop = self.chrome.bounds.height + self.view.safeAreaInsets.bottom + 12
            self.chrome.transform = hidden ? CGAffineTransform(translationX: 0, y: drop) : .identity
            self.chrome.alpha = hidden ? 0 : 1
            self.compactPill.alpha = hidden ? 1 : 0
        }
        if animated {
            // Critically damped: the bars glide, they do not bounce.
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
        applyBottomInset()
    }

    /// ⋯ ▸ Hide Buttons folds the row down to the address bar and ⋯; Show Buttons
    /// unfolds it. Remembered across launches.
    private func setButtonsCollapsed(_ collapsed: Bool) {
        buttonsCollapsed = collapsed
        updateChrome()
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.applyButtonsCollapsed()
            self.chrome.layoutIfNeeded()
        } completion: { _ in
            self.applyBottomInset()
        }
    }

    /// Which parts of the row show: typing gets the whole width plus Cancel; folded
    /// leaves ⋯ alone in its capsule.
    private func applyButtonsCollapsed() {
        let editing = urlField.isFirstResponder
        navGroup.isHidden = editing || buttonsCollapsed
        actionGroup.isHidden = editing
        shareButton.isHidden = buttonsCollapsed
        bookmarksButton.isHidden = buttonsCollapsed
        cancelButton.isHidden = !editing
        for view in [navGroup, shareButton, bookmarksButton] as [UIView] {
            view.alpha = view.isHidden ? 0 : 1
        }
    }

    /// The page's own colour behind the status bar — its `theme-color`, else its
    /// background — with the status bar text flipped to stay readable on it.
    private func updateStatusBacking() {
        guard let webView = currentTab?.webView else { return }
        let color = (webView.themeColor ?? webView.underPageBackgroundColor ?? .systemBackground)
            .resolvedColor(with: traitCollection)
        statusBacking.backgroundColor = color
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        let style: UIStatusBarStyle = 0.299 * red + 0.587 * green + 0.114 * blue < 0.5 ? .lightContent : .darkContent
        if style != statusBarStyle {
            statusBarStyle = style
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    // MARK: Address bar gestures

    /// Sideways, or upwards; never while typing, where the finger is moving the caret.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, !urlField.isFirstResponder else { return false }
        let velocity = pan.velocity(in: view)
        return abs(velocity.x) > abs(velocity.y) || velocity.y < 0
    }

    /// Apple's momentum projection: where a flick released at `velocity` would come
    /// to rest. Deciding on this rather than on the release point is what lets a short
    /// fast flick switch tabs.
    private static func projection(of velocity: CGFloat) -> CGFloat {
        let deceleration: CGFloat = 0.998
        return velocity / 1000 * deceleration / (1 - deceleration)
    }

    /// Past a boundary the drag follows less and less, instead of stopping dead.
    private static func rubberBand(_ offset: CGFloat, limit: CGFloat) -> CGFloat {
        let constant: CGFloat = 0.55
        return offset * limit * constant / (limit + constant * abs(offset))
    }

    @objc private func dragAddressBar(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view)
        let velocity = pan.velocity(in: view)
        switch pan.state {
        case .began:
            // Grabbing a settling page picks it up where it is, not where it was going.
            if let settle, settle.isRunning {
                settle.stopAnimation(true)
                self.settle = nil
            }
            barDrag = abs(velocity.x) > abs(velocity.y) ? .sideways : .upwards
            dragStartOffset = webHost.transform.tx
            if barDrag == .upwards {
                currentTab?.captureSnapshot()
                enterLiftedState()
            }
        case .changed:
            if barDrag == .sideways {
                dragPages(to: dragStartOffset + translation.x)
            } else {
                liftPage(translation.y)
            }
        case .ended, .cancelled:
            if barDrag == .sideways {
                releasePages(velocity: pan.state == .ended ? velocity.x : 0)
            } else {
                releaseLift(translation.y, velocity: pan.state == .ended ? velocity.y : 0)
            }
            barDrag = nil
        default:
            break
        }
    }

    /// The page and its bar follow the finger 1:1, with the neighbouring tab riding
    /// alongside; with no tab that way, the drag rubber-bands.
    private func dragPages(to offset: CGFloat) {
        let forward = offset < 0
        if peekView == nil || peekForward != forward { parkNeighbour(forward: forward) }
        let shown = peekView == nil ? Self.rubberBand(offset, limit: webHost.bounds.width) : offset
        webHost.transform = CGAffineTransform(translationX: shown, y: 0)
        addressPill.transform = CGAffineTransform(translationX: shown, y: 0)
    }

    /// Puts the tab you would land on beside the page, in the same mode. Swiping left
    /// past the last tab offers a fresh one, as Safari does.
    private func parkNeighbour(forward: Bool) {
        peekView?.removeFromSuperview()
        if let tab = peekTab, tab !== currentTab { tab.webView.removeFromSuperview() }
        peekView = nil
        peekTab = nil
        peekForward = forward
        guard let current = currentTab else { return }
        let peers = tabs.filter { $0.isPrivate == current.isPrivate }
        guard let index = peers.firstIndex(where: { $0 === current }) else { return }
        let target = index + (forward ? 1 : -1)
        let width = webHost.bounds.width
        let frame = webHost.bounds.offsetBy(dx: forward ? width : -width, dy: 0)
        if peers.indices.contains(target) {
            let neighbour = peers[target]
            neighbour.loadIfRestored()
            neighbour.webView.frame = frame
            neighbour.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            webHost.addSubview(neighbour.webView)
            peekView = neighbour.webView
            peekTab = neighbour
        } else if forward {
            let blank = UIView(frame: frame)
            blank.backgroundColor = current.isPrivate ? UIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)
                                                      : UIColor(red: 0.11, green: 0.07, blue: 0.25, alpha: 1)
            webHost.addSubview(blank)
            peekView = blank
        }
    }

    private func releasePages(velocity: CGFloat) {
        let width = webHost.bounds.width
        let offset = webHost.transform.tx
        let resting = offset + Self.projection(of: velocity)
        let commit = peekView != nil && abs(resting) > width / 2 && (resting < 0) == peekForward
        let target: CGFloat = commit ? (peekForward ? -width : width) : 0
        // Hand the finger's speed to the spring, relative to the distance left.
        let distance = target - offset
        let initial = distance == 0 ? 0 : max(-20, min(20, velocity / distance))
        let animator = UIViewPropertyAnimator(duration: 0.4, timingParameters: UISpringTimingParameters(
            dampingRatio: 1, initialVelocity: CGVector(dx: initial, dy: 0)))
        animator.addAnimations {
            self.webHost.transform = CGAffineTransform(translationX: target, y: 0)
            self.addressPill.transform = CGAffineTransform(translationX: target, y: 0)
        }
        animator.addCompletion { position in
            guard position == .end else { return }
            self.settle = nil
            if commit { self.completeSwitch() } else { self.clearNeighbour() }
        }
        settle = animator
        animator.startAnimation()
    }

    /// The neighbour is already exactly where the page will be, so swapping it in and
    /// zeroing the offset in one step is invisible. Its bar then slides in from the
    /// side the page came from.
    private func completeSwitch() {
        let forward = peekForward
        let tab = peekTab
        UIView.performWithoutAnimation {
            webHost.transform = .identity
            if tab == nil { peekView?.removeFromSuperview() }
        }
        peekView = nil
        peekTab = nil
        if let tab {
            select(tab)
        } else if let current = currentTab {
            newTab(private: current.isPrivate, focus: false)
        }
        let width = webHost.bounds.width
        addressPill.transform = CGAffineTransform(translationX: forward ? width : -width, y: 0)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.allowUserInteraction]) {
            self.addressPill.transform = .identity
        }
    }

    private func clearNeighbour() {
        peekView?.removeFromSuperview()
        if let tab = peekTab, tab !== currentTab { tab.webView.removeFromSuperview() }
        peekView = nil
        peekTab = nil
        webHost.transform = .identity
        addressPill.transform = .identity
    }

    /// The page follows the finger as a card: it keeps the screen's shape, shrinks the
    /// higher it goes, and its bottom edge stays under the finger — Safari's lift.
    private func liftPage(_ dy: CGFloat) {
        let lift = max(0, -dy)
        let scale = max(0.4, 1 - lift / (view.bounds.height * 1.1))
        let height = webHost.bounds.height
        let restingBottom = webHost.center.y + height / 2
        let shift = (restingBottom - lift) - (webHost.center.y + scale * height / 2)
        webHost.transform = CGAffineTransform(translationX: 0, y: shift).scaledBy(x: scale, y: scale)
    }

    /// Projected far enough (or flicked), the card flies into the overview; otherwise
    /// it springs back into the page.
    private func releaseLift(_ dy: CGFloat, velocity: CGFloat) {
        if max(0, -dy) + Self.projection(of: -velocity) > 140 {
            presentOverview(releaseVelocity: velocity)
            return
        }
        let animator = UIViewPropertyAnimator(duration: 0.4, timingParameters: UISpringTimingParameters(dampingRatio: 1))
        animator.addAnimations {
            self.webHost.transform = .identity
            self.webHost.layer.cornerRadius = 0
            self.chrome.alpha = self.chromeHidden ? 0 : 1
            self.compactPill.alpha = self.chromeHidden ? 1 : 0
            self.statusBacking.alpha = 1
        }
        animator.addCompletion { _ in self.leaveLiftedState() }
        animator.startAnimation()
    }

    /// The same move without the gesture, for the accessibility actions.
    private func stepTab(forward: Bool) -> Bool {
        guard let current = currentTab else { return false }
        let peers = tabs.filter { $0.isPrivate == current.isPrivate }
        guard let index = peers.firstIndex(where: { $0 === current }),
              peers.indices.contains(index + (forward ? 1 : -1)) else { return false }
        select(peers[index + (forward ? 1 : -1)])
        return true
    }

    /// Rocket has no background-audio mode, so nothing plays once it leaves the screen
    /// — yet WebKit keeps the last page audio on the lock screen as Now Playing, with
    /// no way to dismiss it. Suspending a page's media makes it ineligible for that
    /// slot. Paused first so that un-suspending on return resumes nothing by itself.
    func setMediaSuspended(_ suspended: Bool) {
        for tab in tabs {
            if suspended {
                tab.webView.pauseAllMediaPlayback {
                    tab.webView.setAllMediaPlaybackSuspended(true)
                }
            } else {
                tab.webView.setAllMediaPlaybackSuspended(false)
            }
        }
    }
}
