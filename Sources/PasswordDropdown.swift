import Cocoa

enum PasswordDropdownItem {
    case account(PasswordEntry, showsHost: Bool)
    case strongPassword
    case manage
    case caption(String)

    var isSelectable: Bool {
        if case .caption = self { return false }
        return true
    }
}

final class PasswordDropdownRow: NSView {

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let onClick: (Int) -> Void
    private var index = 0
    private var selectable = true

    var isHighlighted = false {
        didSet {
            let lit = isHighlighted && selectable
            layer?.backgroundColor = lit ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor
            titleLabel.textColor = lit ? .white : (selectable ? .labelColor : .secondaryLabelColor)
            subtitleLabel.textColor = lit ? .white.withAlphaComponent(0.8) : .secondaryLabelColor
            iconView.contentTintColor = lit ? .white : .secondaryLabelColor
        }
    }

    init(onClick: @escaping (Int) -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        iconView.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 12.5)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        for view in [iconView, titleLabel, subtitleLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            subtitleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(with item: PasswordDropdownItem, index: Int) {
        self.index = index
        selectable = item.isSelectable
        let symbol: String
        let title: String
        var subtitle = ""
        switch item {
        case .account(let entry, let showsHost):
            symbol = "person.crop.circle"
            title = entry.username.isEmpty ? "(no username)" : entry.username
            subtitle = showsHost ? SiteMatcher.displayHost(entry.host) : ""
        case .strongPassword:
            symbol = "wand.and.stars"
            title = "Use Strong Password"
            subtitle = "Rocket will offer to save it"
        case .manage:
            symbol = "key.fill"
            title = "Manage Passwords…"
        case .caption(let text):
            symbol = "exclamationmark.triangle"
            title = text
        }
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        isHighlighted = false
    }

    override func mouseEntered(with event: NSEvent) { if selectable { isHighlighted = true } }
    override func mouseExited(with event: NSEvent) { isHighlighted = false }
    override func mouseDown(with event: NSEvent) { if selectable { onClick(index) } }
}

/// The account list under a login field. A child panel of the browser window, so the
/// page never sees it and clicking a row never takes focus away from the field.
final class PasswordDropdown {

    var onAccept: ((PasswordDropdownItem) -> Void)?
    var onSelectionChanged: (() -> Void)?

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 0),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
    private let stack = NSStackView()
    private var rows: [PasswordDropdownRow] = []
    private(set) var items: [PasswordDropdownItem] = []
    private(set) var selectedIndex: Int?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        panel.contentView = background
    }

    /// `anchor` is a screen rectangle (the field, or the toolbar key button).
    func show(_ items: [PasswordDropdownItem], below anchor: NSRect, in window: NSWindow) {
        guard !items.isEmpty else { hide(); return }
        self.items = items
        selectedIndex = nil
        while rows.count < items.count {
            let row = PasswordDropdownRow { [weak self] index in self?.accept(at: index) }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 30).isActive = true
            rows.append(row)
        }
        while rows.count > items.count { rows.removeLast().removeFromSuperview() }
        for (index, item) in items.enumerated() { rows[index].update(with: item, index: index) }

        let width = min(max(anchor.width, 280), 440)
        let height = CGFloat(items.count) * 30 + 8
        panel.setFrame(NSRect(x: anchor.minX, y: anchor.minY - height - 3, width: width, height: height),
                       display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func move(to anchor: NSRect) {
        guard isVisible else { return }
        panel.setFrameOrigin(NSPoint(x: anchor.minX, y: anchor.minY - panel.frame.height - 3))
    }

    func hide() {
        selectedIndex = nil
        items = []
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func moveSelection(by delta: Int) {
        let selectable = items.indices.filter { items[$0].isSelectable }
        guard !selectable.isEmpty else { return }
        let next: Int?
        if let current = selectedIndex, let position = selectable.firstIndex(of: current) {
            let candidate = position + delta
            next = candidate < 0 || candidate >= selectable.count ? nil : selectable[candidate]
        } else {
            next = delta > 0 ? selectable.first : selectable.last
        }
        selectedIndex = next
        for (index, row) in rows.enumerated() { row.isHighlighted = index == next }
        onSelectionChanged?()
    }

    func acceptSelection() {
        guard let selectedIndex else { return }
        accept(at: selectedIndex)
    }

    private func accept(at index: Int) {
        guard index < items.count, items[index].isSelectable else { return }
        onAccept?(items[index])
    }
}
