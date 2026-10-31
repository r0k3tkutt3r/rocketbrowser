import Cocoa
import AVFoundation

/// Right-click ▸ Read Aloud: selected text spoken by Kokoro-82M, on this Mac.
///
/// The model runs in `rocket-speech`, a helper process in Contents/Helpers, because the
/// fastest port on Apple Silicon (kokoro-coreml: Neural Engine + GPU) is a Swift package
/// and Rocket itself is a dependency-free swiftc build. Measured on an M2 Air: a cold
/// helper loads in ~0.4 s and the first audio plays ~0.9 s after the click; warm, 19 s
/// of speech takes 0.7 s, at ~350 MB resident. The helper streams audio a chunk at a
/// time, so playback starts on the first sentence rather than after the whole text.
///
/// The helper is started on the first Read Aloud and stopped `idleTimeout` after the
/// last one ends, which is the only way to give its memory back. The first use ever
/// downloads the ~210 MB model to ~/Library/Caches/kokoro-coreml; the pill says so.
final class ReadAloud {
    static let shared = ReadAloud()

    static let helperURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/RocketSpeech/rocket-speech")

    /// The helper needs macOS 15, and build.sh skips it when SwiftPM cannot build it.
    static var isAvailable: Bool {
        guard #available(macOS 15, *) else { return false }
        return FileManager.default.isExecutableFile(atPath: helperURL.path)
    }

    /// Long enough to read several passages in a row warm; short enough that a model
    /// nobody is using does not sit on a 16 GB machine all afternoon.
    static let idleTimeout: TimeInterval = 5 * 60

    /// Kokoro voice ids. The helper's starter bundle has af_heart; every other voice
    /// must also be listed in its `extraVoices`, or the helper refuses it.
    enum Voice: String, CaseIterable {
        case heart = "af_heart", michael = "am_michael"

        var title: String {
            switch self {
            case .heart: return "Female (Heart)"
            case .michael: return "Male (Michael)"
            }
        }
    }

    static var voice: Voice {
        get { UserDefaults.standard.string(forKey: "ReadAloudVoice").flatMap(Voice.init) ?? .heart }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ReadAloudVoice") }
    }

    enum State: Equatable {
        case idle, downloading(Double), loading, speaking, failed(String)
    }

    private(set) var state = State.idle {
        didSet { if state != oldValue { pill?.show(state) } }
    }
    var isActive: Bool { state == .loading || state == .speaking || isDownloading }
    private var isDownloading: Bool { if case .downloading = state { return true } else { return false } }

    private var process: Process?
    private var input: FileHandle?
    private var pending = Data()
    /// Every request and every stop bumps this; anything the helper sends for an older
    /// id is a cancelled request finishing late and is dropped.
    private var requestID = 0
    private var synthesisDone = false
    private var buffersInFlight = 0
    private var idleTimer: Timer?
    private weak var pill: ReadAloudPill?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Speaks `text`, replacing anything already being read. `view` hosts the pill.
    func speak(_ text: String, in view: NSView) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stop()
        guard launchHelperIfNeeded() else {
            showPill(in: view)
            state = .failed("Read Aloud couldn’t start")
            return
        }
        requestID += 1
        synthesisDone = false
        idleTimer?.invalidate()
        showPill(in: view)
        state = .loading
        send(["id": requestID, "text": text, "voice": Self.voice.rawValue])
    }

    func stop() {
        guard state != .idle else { return }
        requestID += 1
        send(["id": requestID, "text": ""])
        finish()
    }

    // MARK: - Helper process

    private func launchHelperIfNeeded() -> Bool {
        if process?.isRunning == true { return true }
        let process = Process()
        process.executableURL = Self.helperURL
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.helperEnded(ended) }
        }
        do {
            try process.run()
        } catch {
            NSLog("Read Aloud: could not launch helper: \(error)")
            return false
        }
        self.process = process
        input = stdin.fileHandleForWriting
        pending.removeAll()
        return true
    }

    private func helperEnded(_ ended: Process) {
        guard ended === process else { return }
        process = nil
        input = nil
        if state != .idle, !(state.isFailure) {
            finish()
            state = .failed("Read Aloud stopped unexpectedly")
        }
    }

    private func send(_ object: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        // A helper that died between the check and the write raises SIGPIPE-backed
        // exceptions in `write(_:)`; the throwing variant reports it instead.
        try? input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let progress = message["progress"] as? Double {
            if state == .loading || isDownloading { state = .downloading(progress) }
            return
        }
        guard message["id"] as? Int == requestID, state != .idle else { return }
        if let base64 = message["pcm"] as? String, let pcm = Data(base64Encoded: base64) {
            play(pcm)
        } else if message["done"] != nil {
            synthesisDone = true
            if buffersInFlight == 0 { finish() }
        } else if let error = message["error"] as? String {
            NSLog("Read Aloud: \(error)")
            finish()
            state = .failed("Read Aloud failed")
        }
    }

    // MARK: - Playback

    private func play(_ pcm: Data) {
        let frames = AVAudioFrameCount(pcm.count / MemoryLayout<Float>.size)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        _ = pcm.withUnsafeBytes { raw in
            memcpy(channel, raw.baseAddress!, Int(frames) * MemoryLayout<Float>.size)
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                NSLog("Read Aloud: audio engine: \(error)")
                finish()
                state = .failed("No audio output")
                return
            }
        }
        let id = requestID
        buffersInFlight += 1
        // `player.stop()` also fires these, which is why the id is checked.
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, id == self.requestID else { return }
                self.buffersInFlight -= 1
                if self.synthesisDone && self.buffersInFlight == 0 { self.finish() }
            }
        }
        if !player.isPlaying { player.play() }
        state = .speaking
    }

    /// Back to idle: silence, release the audio device, and start the helper's idle clock.
    private func finish() {
        requestID += 1
        player.stop()
        engine.stop()
        buffersInFlight = 0
        synthesisDone = false
        state = .idle
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTimeout, repeats: false) { [weak self] _ in
            // Closing stdin is the helper's cue to exit.
            try? self?.input?.close()
            self?.input = nil
        }
    }

    /// Always a fresh pill: reusing one that is still fading out would let that fade's
    /// completion remove it from under the new request.
    private func showPill(in view: NSView) {
        pill?.removeFromSuperview()
        let pill = ReadAloudPill { [weak self] in self?.stop() }
        pill.attach(to: view)
        self.pill = pill
    }
}

private extension ReadAloud.State {
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}

/// The floating control at the bottom of the page while Rocket reads: what it is doing,
/// and a stop button. It belongs to the tab that started reading, so it is where you
/// left it when you come back to that tab.
final class ReadAloudPill: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let stopButton = NSButton()
    private let onStop: () -> Void
    private var hideWork: DispatchWorkItem?

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            return shadow
        }()

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        stopButton.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Reading")
        stopButton.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        stopButton.isBordered = false
        stopButton.contentTintColor = .secondaryLabelColor
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.toolTip = "Stop Reading"

        let stack = NSStackView(views: [spinner, label, stopButton])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 34),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func attach(to view: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        alphaValue = 0
        view.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
    }

    func show(_ state: ReadAloud.State) {
        hideWork?.cancel()
        switch state {
        case .idle:
            fade(to: 0) { [weak self] in self?.removeFromSuperview() }
            return
        case .loading:
            label.stringValue = "Loading voice…"
            spinner.startAnimation(nil)
        case .downloading(let fraction):
            label.stringValue = "Downloading voice… \(Int(fraction * 100))%"
            spinner.startAnimation(nil)
        case .speaking:
            label.stringValue = "Reading Aloud"
            spinner.stopAnimation(nil)
        case .failed(let message):
            label.stringValue = message
            spinner.stopAnimation(nil)
            // A failure is news, not a control: it leaves by itself.
            let work = DispatchWorkItem { [weak self] in
                self?.fade(to: 0) { self?.removeFromSuperview() }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
        stopButton.isHidden = state.isFailure
        setAccessibilityLabel(label.stringValue)
        fade(to: 1)
    }

    @objc private func stopClicked() {
        onStop()
    }

    private func fade(to alpha: CGFloat, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = alpha
        }, completionHandler: completion)
    }
}
