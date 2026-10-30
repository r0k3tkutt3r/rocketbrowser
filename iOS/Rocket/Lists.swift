import UIKit

/// The three sheets: open tabs, bookmarks, history. Each is a plain table over a store
/// the Mac app already has; none of them keeps a copy of the data.

// MARK: - Tabs

/// Safari's tab overview: a grid of cards for one mode at a time, with the switch
/// between normal tabs and incognito at the top. Switching back from incognito is how
/// incognito ends — every private tab closes at once and the session's data is wiped.
final class TabsViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {

    private weak var browser: BrowserViewController?
    private var showingPrivate: Bool
    private let modeSwitch = UISegmentedControl(items: [
        UIImage(systemName: "eyeglasses")!.withConfiguration(UIImage.SymbolConfiguration(weight: .semibold)),
        "Tabs",
    ])
    private lazy var grid = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout {
        [weak self] _, environment in
        Self.section(lone: self?.shownTabs.count == 1, width: environment.container.effectiveContentSize.width)
    })
    private let toolbar = UIToolbar()
    private let countLabel = UILabel()

    /// The mode's tabs as the browser has them right now — for deciding what to do.
    private var tabs: [Tab] { browser?.tabs.filter { $0.isPrivate == showingPrivate } ?? [] }
    /// The cards on screen, and the grid's only data source. It changes only together
    /// with the grid, never behind its back: + creates a tab before the overview
    /// closes, and when `tabs` fed the grid, the closing animation asked for a card
    /// the grid did not have and UIKit aborted the app (every + crashed).
    private var shownTabs: [Tab] = []

    init(browser: BrowserViewController) {
        self.browser = browser
        showingPrivate = browser.currentTab?.isPrivate ?? false
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func section(lone: Bool, width: CGFloat) -> NSCollectionLayoutSection {
        if lone {
            // One tab is shown large and centred, as Safari does.
            let cardWidth = min(width * 0.62, 320)
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                heightDimension: .estimated(420)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(cardWidth),
                                                                             heightDimension: .estimated(420)),
                                                           subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            let side = (width - cardWidth) / 2
            section.contentInsets = .init(top: 24, leading: side, bottom: 12, trailing: side)
            return section
        }
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(0.5),
                                                            heightDimension: .estimated(280)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                         heightDimension: .estimated(280)),
                                                       subitems: [item, item])
        group.interItemSpacing = .fixed(16)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 20
        section.contentInsets = .init(top: 12, leading: 16, bottom: 12, trailing: 16)
        return section
    }

    // MARK: Cards (used by TabOverviewTransition)

    /// Where `tab`'s picture sits in the grid, in `space`'s coordinates — scrolled into
    /// view first if it is off screen, so the page has somewhere visible to fly to.
    func cardFrame(for tab: Tab?, in space: UIView) -> CGRect? {
        guard let tab, let index = shownTabs.firstIndex(where: { $0 === tab }) else { return nil }
        loadViewIfNeeded()
        view.layoutIfNeeded()
        grid.layoutIfNeeded()
        let path = IndexPath(item: index, section: 0)
        if !grid.indexPathsForVisibleItems.contains(path) {
            grid.scrollToItem(at: path, at: .centeredVertically, animated: false)
            grid.layoutIfNeeded()
        }
        guard let card = grid.cellForItem(at: path) as? TabCard else { return nil }
        card.layoutIfNeeded()
        return card.pictureFrame(in: space)
    }

    /// The card stands aside while the real page flies in or out of its place, and
    /// comes back showing the picture taken on the way in.
    func setCard(for tab: Tab?, hidden: Bool) {
        guard let tab, let index = shownTabs.firstIndex(where: { $0 === tab }) else { return }
        let path = IndexPath(item: index, section: 0)
        if !hidden { grid.reconfigureItems(at: [path]) }
        (grid.cellForItem(at: path) as? TabCard)?.setPictureHidden(hidden)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        modeSwitch.setWidth(90, forSegmentAt: 0)
        modeSwitch.setWidth(90, forSegmentAt: 1)
        modeSwitch.selectedSegmentIndex = showingPrivate ? 0 : 1
        modeSwitch.accessibilityLabel = "Incognito or normal tabs"
        modeSwitch.addAction(UIAction { [weak self] _ in self?.modeChanged() }, for: .valueChanged)

        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.register(TabCard.self, forCellWithReuseIdentifier: "card")

        countLabel.font = .preferredFont(forTextStyle: .headline)
        countLabel.textAlignment = .center
        toolbar.items = [
            UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.addTab() }),
            .flexibleSpace(),
            UIBarButtonItem(customView: countLabel),
            .flexibleSpace(),
            UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.finish() }),
        ]

        for subview in [grid, modeSwitch, toolbar] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            modeSwitch.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            modeSwitch.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.topAnchor.constraint(equalTo: modeSwitch.bottomAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
        ])
        refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The cards scroll under the floating toolbar, and clear it at the end.
        grid.contentInset.bottom = max(0, view.bounds.maxY - toolbar.frame.minY)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let current = browser?.currentTab, let index = shownTabs.firstIndex(where: { $0 === current }) {
            grid.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: false)
        }
    }

    private func refresh() {
        // Incognito is always dark, as everywhere else.
        overrideUserInterfaceStyle = showingPrivate ? .dark : .unspecified
        shownTabs = tabs
        grid.reloadData()
        updateCount()
    }

    private func updateCount() {
        let count = shownTabs.count
        countLabel.text = showingPrivate
            ? (count == 1 ? "1 Incognito Tab" : "\(count) Incognito Tabs")
            : (count == 1 ? "1 Tab" : "\(count) Tabs")
        countLabel.sizeToFit()
        setNeedsUpdateContentUnavailableConfiguration()
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        guard showingPrivate, shownTabs.isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        var empty = UIContentUnavailableConfiguration.empty()
        empty.image = UIImage(systemName: "eyeglasses")
        empty.text = "Incognito"
        empty.secondaryText = """
        Incognito tabs share one private session. Switching back to Tabs closes them all \
        and deletes their cookies and site data.
        """
        contentUnavailableConfiguration = empty
    }

    /// Through black, over a second: the switch is the move between two places.
    private func modeChanged() {
        let toPrivate = modeSwitch.selectedSegmentIndex == 0
        let apply = { [weak self] in
            guard let self else { return }
            self.showingPrivate = toPrivate
            if !toPrivate { self.browser?.closePrivateTabs() }
            self.refresh()
        }
        if let window = view.window {
            window.fadeThroughBlack(midpoint: apply)
        } else {
            apply()
        }
    }

    /// The tab exists before the overview fades, so the fade reveals it rather than
    /// the tab that was up before. The keyboard waits: a field under a full-screen
    /// cover cannot become first responder.
    private func addTab() {
        browser?.newTab(private: showingPrivate, focus: false)
        dismiss(animated: true) { [weak browser] in browser?.focusAddressBar() }
    }

    /// Back to the page: the current tab if it belongs to this mode, otherwise the
    /// mode's last tab, or a fresh one when the mode has none.
    private func finish() {
        guard let browser else { return dismiss(animated: true) }
        let tabs = self.tabs
        if let current = browser.currentTab, tabs.contains(where: { $0 === current }) {
            dismiss(animated: true)
        } else if let last = tabs.last {
            browser.select(last)
            dismiss(animated: true)
        } else {
            addTab()
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        shownTabs.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let card = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath) as! TabCard
        let tab = shownTabs[indexPath.item]
        card.show(tab, isCurrent: tab === browser?.currentTab)
        card.onClose = { [weak self] in self?.close(tab) }
        return card
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        browser?.select(shownTabs[indexPath.item])
        dismiss(animated: true)
    }

    private func close(_ tab: Tab) {
        guard let index = shownTabs.firstIndex(where: { $0 === tab }) else { return }
        browser?.close(tab)
        var expected = shownTabs
        expected.remove(at: index)
        // Only a plain removal animates; closing the last normal tab opens a fresh one,
        // and anything else is simply redrawn.
        guard tabs.elementsEqual(expected, by: ===) else { return refresh() }
        shownTabs = expected
        grid.deleteItems(at: [IndexPath(item: index, section: 0)])
        // Down to one card: it becomes the large centred one.
        if shownTabs.count == 1 { grid.collectionViewLayout.invalidateLayout() }
        updateCount()
        // The current-tab outline may have moved to a neighbour.
        grid.reconfigureItems(at: grid.indexPathsForVisibleItems)
    }
}

/// One card: the page's picture with a close button, and its title underneath.
private final class TabCard: UICollectionViewCell {

    var onClose: (() -> Void)?
    private let picture = UIImageView()
    private let icon = UIImageView()
    private let title = UILabel()
    private let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = 18
        picture.layer.cornerCurve = .continuous
        picture.backgroundColor = .secondarySystemGroupedBackground
        picture.tintColor = .tertiaryLabel

        var close = UIButton.Configuration.gray()
        close.image = UIImage(systemName: "xmark",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        close.cornerStyle = .capsule
        close.baseForegroundColor = .secondaryLabel
        close.contentInsets = .init(top: 7, leading: 7, bottom: 7, trailing: 7)
        closeButton.configuration = close
        closeButton.accessibilityLabel = "Close Tab"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        title.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        title.adjustsFontForContentSizeCategory = true

        let caption = UIStackView(arrangedSubviews: [icon, title])
        caption.spacing = 6
        caption.alignment = .center
        for subview in [picture, closeButton, caption] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: contentView.topAnchor),
            picture.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: 4.0 / 3.0),
            closeButton.topAnchor.constraint(equalTo: picture.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: picture.trailingAnchor, constant: -8),
            caption.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 8),
            caption.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -4),
            caption.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func pictureFrame(in space: UIView) -> CGRect {
        picture.convert(picture.bounds, to: space)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setPictureHidden(false)
    }

    /// Only the picture steps aside for the flying page; the title stays, so the card
    /// reads as finished the moment the page lands on it.
    func setPictureHidden(_ hidden: Bool) {
        picture.alpha = hidden ? 0 : 1
        closeButton.alpha = hidden ? 0 : 1
    }

    func show(_ tab: Tab, isCurrent: Bool) {
        if let snapshot = tab.snapshot {
            picture.image = snapshot
            picture.contentMode = .scaleAspectFill
        } else {
            // Restored tabs that have not been shown yet have no picture to offer.
            picture.image = UIImage(systemName: "globe",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 34))
            picture.contentMode = .center
        }
        picture.layer.borderWidth = isCurrent ? 3 : 0
        picture.layer.borderColor = tintColor.cgColor
        icon.image = UIImage(systemName: tab.isPrivate ? "eyeglasses" : "globe")
        title.text = tab.title
        accessibilityLabel = tab.title
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: 0) } ?? self
    }
}

// MARK: - Bookmarks

final class BookmarksViewController: UITableViewController {

    private let folderID: UUID?
    private let onOpen: (URL) -> Void
    private var observer: NSObjectProtocol?

    init(folderID: UUID?, onOpen: @escaping (URL) -> Void) {
        self.folderID = folderID
        self.onOpen = onOpen
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Looked up fresh every time: the store owns the tree, and a folder can change
    /// (or vanish) while this screen is open.
    private var items: [Bookmark] {
        let store = BookmarkStore.shared
        guard let folderID else { return store.items }
        return BookmarkStore.firstItem(withID: folderID, in: store.items)?.children ?? []
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = folderID.flatMap { BookmarkStore.firstItem(withID: $0, in: BookmarkStore.shared.items)?.title }
            ?? "Bookmarks"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        observer = NotificationCenter.default.addObserver(forName: .bookmarksDidChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            self?.tableView.reloadData()
            self?.setNeedsUpdateContentUnavailableConfiguration()
        }
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        guard items.isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        var empty = UIContentUnavailableConfiguration.empty()
        empty.image = UIImage(systemName: "book")
        empty.text = "No Bookmarks"
        empty.secondaryText = folderID == nil ? "Add one from the ⋯ menu while viewing a page." : nil
        contentUnavailableConfiguration = empty
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = items[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.subtitleCell()
        content.text = item.title
        content.image = UIImage(systemName: item.isFolder ? "folder" : "star")
        if let url = item.url.flatMap(URL.init(string:)) {
            content.secondaryText = url.host.map(URLDisplay.rootDomain)
            content.secondaryTextProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = content
        cell.accessoryType = item.isFolder ? .disclosureIndicator : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = items[indexPath.row]
        if item.isFolder {
            navigationController?.pushViewController(BookmarksViewController(folderID: item.id, onOpen: onOpen),
                                                     animated: true)
        } else if let url = item.url.flatMap(URL.init(string:)) {
            onOpen(url)
        }
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = items[indexPath.row]
        return UISwipeActionsConfiguration(actions: [
            UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
                // The store posts .bookmarksDidChange, which reloads this table.
                BookmarkStore.shared.removeItem(id: item.id)
                done(true)
            },
        ])
    }
}

// MARK: - History

/// Searches raw, never through `HistoryRanker` — the same rule as the Mac's ⌘Y window:
/// finding the one-off page the ranker hides is what this screen is for.
final class HistoryViewController: UITableViewController, UISearchResultsUpdating {

    private let onOpen: (URL) -> Void
    private var sections: [(title: String, visits: [Visit])] = []
    private var observer: NSObjectProtocol?
    private let search = UISearchController(searchResultsController: nil)

    init(onOpen: @escaping (URL) -> Void) {
        self.onOpen = onOpen
        super.init(style: .insetGrouped)
        title = "History"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Clear", primaryAction: UIAction { [weak self] _ in
            self?.confirmClear()
        })
        observer = NotificationCenter.default.addObserver(forName: .historyDidChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    func updateSearchResults(for searchController: UISearchController) {
        reload()
    }

    private func reload() {
        sections = []
        for row in HistoryGrouping.rows(for: HistoryStore.shared.visits, query: search.searchBar.text ?? "") {
            switch row {
            case .header(let title): sections.append((title, []))
            case .visit(let visit): sections[sections.count - 1].visits.append(visit)
            }
        }
        tableView.reloadData()
        setNeedsUpdateContentUnavailableConfiguration()
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        guard sections.isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        var empty = UIContentUnavailableConfiguration.empty()
        empty.image = UIImage(systemName: "clock")
        empty.text = "No History"
        // History is gated on suggestions, as on the Mac — say so rather than look broken.
        if !SuggestionEngine.shared.isEnabled {
            empty.secondaryText = "History is only kept while ⋯ ▸ Settings ▸ New Tab Suggestions is on."
        }
        contentUnavailableConfiguration = empty
    }

    private func confirmClear() {
        let alert = UIAlertController(title: "Clear all history?",
                                      message: "This also resets new tab suggestions, which are learned from it.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear History", style: .destructive) { _ in
            SuggestionEngine.shared.reset()
        })
        present(alert, animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].visits.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let visit = sections[indexPath.section].visits[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "visit")
            ?? UITableViewCell(style: .default, reuseIdentifier: "visit")
        var content = UIListContentConfiguration.subtitleCell()
        content.text = visit.displayTitle
        content.secondaryText = HistoryGrouping.timeLabel(for: visit.ts) + " · " + HistoryGrouping.subtitle(for: visit)
        content.secondaryTextProperties.color = .secondaryLabel
        content.textProperties.numberOfLines = 1
        content.secondaryTextProperties.numberOfLines = 1
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let visit = sections[indexPath.section].visits[indexPath.row]
        if let url = URL(string: visit.url) { onOpen(url) }
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let visit = sections[indexPath.section].visits[indexPath.row]
        return UISwipeActionsConfiguration(actions: [
            UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
                // The store posts .historyDidChange, which rebuilds the sections.
                HistoryStore.shared.remove(ids: [visit.id])
                done(true)
            },
        ])
    }
}
