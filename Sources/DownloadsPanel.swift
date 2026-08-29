import Cocoa

/// A progress bar that can be split into several independently-filling segments: one per
/// connection for a chunked download, or a single segment for the aggregate total.
final class SegmentedProgressView: NSView {

    var fractions: [Double] = [] {
        didSet {
            guard fractions != oldValue else { return }
            needsDisplay = true
        }
    }

    private let gap: CGFloat = 3

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !fractions.isEmpty, bounds.width > 0 else { return }
        let count = CGFloat(fractions.count)
        let width = (bounds.width - gap * (count - 1)) / count
        guard width > 0 else { return }
        let radius = bounds.height / 2

        for (index, fraction) in fractions.enumerated() {
            let x = (width + gap) * CGFloat(index)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: width, height: bounds.height),
                         xRadius: radius, yRadius: radius).fill()

            let filled = width * CGFloat(min(max(fraction, 0), 1))
            guard filled > 0 else { continue }
            NSColor.controlAccentColor.setFill()
            // Cap the corner radius at half the fill, or a barely-started segment draws as
            // a lozenge wider than the progress it represents.
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: filled, height: bounds.height),
                         xRadius: min(radius, filled / 2), yRadius: radius).fill()
        }
    }
}

/// One row in the downloads popover: name, progress, "4.2 MB of 18 MB — 2.3 MB/s", and the
/// VirusTotal verdict when there is one. A chunked download shows its four connections as a
/// split bar with the aggregate total underneath; everything else keeps the single bar.
final class DownloadRowView: NSView {

    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let scanLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let chunkBars = SegmentedProgressView()
    private let totalBar = SegmentedProgressView()
    private let barsStack = NSStackView()
    private let actionButton = NSButton()
    private var item: DownloadItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        icon.imageScaling = .scaleProportionallyDown
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        scanLabel.font = .systemFont(ofSize: 10)
        scanLabel.lineBreakMode = .byTruncatingTail

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.style = .bar

        actionButton.bezelStyle = .circular
        actionButton.isBordered = false
        actionButton.target = self
        actionButton.action = #selector(actionTapped)

        // A stack so the split bar can collapse out of layout entirely for the ordinary
        // single-connection case, rather than leaving a gap behind a hidden view.
        barsStack.orientation = .vertical
        barsStack.spacing = 3
        barsStack.alignment = .leading
        barsStack.addArrangedSubview(chunkBars)
        barsStack.addArrangedSubview(totalBar)
        barsStack.addArrangedSubview(progress)

        for view in [icon, nameLabel, statusLabel, scanLabel, barsStack, actionButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),

            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            nameLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),

            barsStack.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            barsStack.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            barsStack.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),

            // The per-connection bars sit thinner than the aggregate below them, so the
            // total reads as the headline and the four chunks as the detail.
            chunkBars.widthAnchor.constraint(equalTo: barsStack.widthAnchor),
            chunkBars.heightAnchor.constraint(equalToConstant: 3),
            totalBar.widthAnchor.constraint(equalTo: barsStack.widthAnchor),
            totalBar.heightAnchor.constraint(equalToConstant: 5),
            progress.widthAnchor.constraint(equalTo: barsStack.widthAnchor),
            progress.heightAnchor.constraint(equalToConstant: 4),

            statusLabel.topAnchor.constraint(equalTo: barsStack.bottomAnchor, constant: 3),
            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),

            scanLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 1),
            scanLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            scanLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            scanLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -7),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 22),
            actionButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with item: DownloadItem) {
        self.item = item
        nameLabel.stringValue = item.filename
        statusLabel.stringValue = item.statusLine

        if let destination = item.destination {
            icon.image = NSWorkspace.shared.icon(forFile: destination.path)
        }

        let running = item.state == .running
        let fractions = running ? (item.chunked?.chunkFractions ?? []) : []
        let isSplit = fractions.count > 1

        chunkBars.isHidden = !isSplit
        totalBar.isHidden = !isSplit
        progress.isHidden = running ? isSplit : true

        if isSplit {
            chunkBars.fractions = fractions
            totalBar.fractions = [item.fractionCompleted]
        } else if running {
            if item.totalBytes > 0 {
                progress.isIndeterminate = false
                progress.doubleValue = item.fractionCompleted
            } else {
                progress.isIndeterminate = true
                progress.startAnimation(nil)
            }
        }

        if let line = item.scanLine {
            scanLabel.isHidden = false
            scanLabel.stringValue = line
            switch item.scan {
            case .flagged: scanLabel.textColor = .systemRed
            case .clean: scanLabel.textColor = .systemGreen
            default: scanLabel.textColor = .tertiaryLabelColor
            }
        } else {
            scanLabel.isHidden = true
            scanLabel.stringValue = ""
        }

        let symbol = running ? "xmark.circle.fill" : "magnifyingglass.circle.fill"
        actionButton.image = NSImage(systemSymbolName: symbol,
                                     accessibilityDescription: running ? "Cancel" : "Show in Finder")
        actionButton.toolTip = running ? "Cancel" : "Show in Finder"
        actionButton.isHidden = item.state == .cancelled || item.destination == nil
    }

    @objc private func actionTapped() {
        guard let item else { return }
        if item.state == .running {
            DownloadsManager.shared.cancel(item)
        } else {
            DownloadsManager.shared.reveal(item)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Double-click shows the file in Finder rather than launching it — opening an
        // unrecognised download by accident is exactly the mistake worth not making.
        if event.clickCount == 2, let item, item.destination != nil {
            DownloadsManager.shared.reveal(item)
        }
        super.mouseDown(with: event)
    }
}

/// AppKit lays an unflipped scroll view's content out from the bottom, which parks a
/// short list at the bottom of the popover. Flipping the clip view fills from the top.
final class TopAnchoredClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// The popover contents: a scrolling list of downloads with a "Clear" button.
final class DownloadsViewController: NSViewController {

    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No downloads yet")
    private let clearButton = NSButton()
    private var observer: NSObjectProtocol?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 260))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.contentView = TopAnchoredClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        clearButton.title = "Clear"
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(clearButton)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -12),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -6),
            clearButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            clearButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: .downloadsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    /// Rows are taller when a scan verdict has to fit underneath the status line, and
    /// taller again when a chunked download needs the split bar as well as the total.
    private func height(for item: DownloadItem) -> CGFloat {
        var height: CGFloat = item.scanLine == nil ? 56 : 68
        if item.state == .running, (item.chunked?.chunkFractions.count ?? 0) > 1 { height += 7 }
        return height
    }

    private func reload() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        let items = DownloadsManager.shared.items
        emptyLabel.isHidden = !items.isEmpty
        clearButton.isEnabled = items.contains { $0.state != .running }

        for item in items {
            let row = DownloadRowView()
            row.configure(with: item)
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: stack.widthAnchor),
                row.heightAnchor.constraint(equalToConstant: height(for: item)),
            ])
        }

        // Grow with the list rather than reserving a fixed slab of empty space.
        let listHeight = items.isEmpty ? 56 : items.reduce(0) { $0 + height(for: $1) }
        let footer: CGFloat = 42
        preferredContentSize = NSSize(width: 380, height: min(listHeight + footer, 380))
    }

    @objc private func clearTapped() {
        DownloadsManager.shared.clearFinished()
    }
}
