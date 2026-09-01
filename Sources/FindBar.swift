import Cocoa

/// The find bar, sitting between the bookmarks bar and the page the way Safari's does.
///
/// It owns no search state — it reports what the user typed and pressed, and renders
/// whatever counts `FindController` hands back.
final class FindBarView: NSVisualEffectView, NSSearchFieldDelegate {

    let field = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let doneButton = NSButton()
    private let separator = NSBox()

    var onQueryChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    static let barHeight: CGFloat = 36

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .titlebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Building

    private func build() {
        field.placeholderString = "Find on page"
        field.delegate = self
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = false
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .default

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configure(previousButton, symbol: "chevron.up", label: "Find Previous",
                  action: #selector(previousTapped))
        configure(nextButton, symbol: "chevron.down", label: "Find Next",
                  action: #selector(nextTapped))

        doneButton.title = "Done"
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .small
        doneButton.font = .systemFont(ofSize: 11)
        doneButton.target = self
        doneButton.action = #selector(doneTapped)

        separator.boxType = .separator

        let stack = NSStackView(views: [field, countLabel, previousButton, nextButton, doneButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(10, after: countLabel)
        stack.setCustomSpacing(2, after: previousButton)
        stack.setCustomSpacing(10, after: nextButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(separator)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 260),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        // The bar is height-clamped to zero when hidden, so nothing inside it may
        // insist on a taller layout.
        for view in [field, countLabel, previousButton, nextButton, doneButton, stack] {
            view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
        showResults(total: 0, index: -1, scanning: false)
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.target = self
        button.action = action
    }

    // MARK: - State

    /// `index` is 0-based, or -1 when nothing is highlighted.
    func showResults(total: Int, index: Int, scanning: Bool) {
        let hasQuery = !field.stringValue.isEmpty
        if !hasQuery {
            countLabel.stringValue = ""
            countLabel.textColor = .secondaryLabelColor
        } else if total == 0 {
            // While an image scan is still running, "no results" would be a lie.
            countLabel.stringValue = scanning ? "Reading images…" : "No results"
            countLabel.textColor = scanning ? .secondaryLabelColor : .systemRed
        } else {
            let position = max(0, index) + 1
            countLabel.stringValue = scanning
                ? "\(position) of \(total) · reading images…"
                : "\(position) of \(total)"
            countLabel.textColor = .secondaryLabelColor
        }
        previousButton.isEnabled = total > 0
        nextButton.isEnabled = total > 0
    }

    func focusField(selectingAll: Bool = true) {
        window?.makeFirstResponder(field)
        if selectingAll { field.currentEditor()?.selectAll(nil) }
    }

    // MARK: - Actions

    @objc private func nextTapped() { onNext?() }
    @objc private func previousTapped() { onPrevious?() }
    @objc private func doneTapped() { onClose?() }

    // MARK: - Field delegate

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === field else { return }
        onQueryChanged?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === field else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // AppKit sends insertNewline: for ⇧Return too, so the direction has to come
            // from the event rather than the selector.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
