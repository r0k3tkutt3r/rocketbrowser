import Foundation
import WebKit

extension Notification.Name {
    static let downloadsDidChange = Notification.Name("RocketDownloadsDidChange")
}

/// One download, live or finished. Owned by `DownloadsManager` so a download keeps
/// running (and stays listed) after the tab that started it is closed.
final class DownloadItem {

    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    enum Scan: Equatable {
        case notRequested          // policy said this file did not need scanning
        case working(String)       // hashing / querying / uploading
        case clean(engines: Int)
        case flagged(malicious: Int, engines: Int)
        case unknown               // VirusTotal has never seen this file
        case unavailable(String)   // no key, rate limited, offline…
    }

    let id = UUID()
    let startedAt = Date()
    weak var download: WKDownload?

    var filename: String
    var destination: URL?
    var totalBytes: Int64 = 0
    var receivedBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    var state: State = .running
    var scan: Scan = .notRequested
    var risk: DownloadRisk = .benign

    /// Previous sample, for the speed estimate.
    var lastSampleBytes: Int64 = 0
    var lastSampleTime = Date()

    init(filename: String) {
        self.filename = filename
    }

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    /// "4.2 MB of 18.1 MB — 2.3 MB/s" while running, a plain size once done.
    var statusLine: String {
        switch state {
        case .running:
            let received = Self.format(bytes: receivedBytes)
            let speed = bytesPerSecond > 0 ? " — \(Self.format(bytes: Int64(bytesPerSecond)))/s" : ""
            if totalBytes > 0 {
                let remaining = remainingText()
                return "\(received) of \(Self.format(bytes: totalBytes))\(speed)\(remaining)"
            }
            return "\(received)\(speed)"
        case .finished:
            return Self.format(bytes: max(receivedBytes, totalBytes))
        case .failed(let message):
            return "Failed — \(message)"
        case .cancelled:
            return "Cancelled"
        }
    }

    private func remainingText() -> String {
        guard bytesPerSecond > 1, totalBytes > receivedBytes else { return "" }
        let seconds = Double(totalBytes - receivedBytes) / bytesPerSecond
        guard seconds.isFinite, seconds < 86400 else { return "" }
        if seconds < 60 { return " — \(Int(seconds))s left" }
        if seconds < 3600 { return " — \(Int(seconds / 60))m left" }
        return " — \(Int(seconds / 3600))h left"
    }

    var scanLine: String? {
        switch scan {
        case .notRequested: return nil
        case .working(let stage): return stage
        case .clean(let engines): return "No threats found (\(engines) engines)"
        case .flagged(let malicious, let engines): return "⚠️ Flagged by \(malicious) of \(engines) engines"
        case .unknown: return "Not seen by VirusTotal before"
        case .unavailable(let reason): return "Scan unavailable — \(reason)"
        }
    }

    static func format(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

/// Owns every download in the app: progress, speed, and the optional VirusTotal check.
final class DownloadsManager: NSObject, WKDownloadDelegate {

    static let shared = DownloadsManager()

    private(set) var items: [DownloadItem] = []
    private var itemsByDownload: [ObjectIdentifier: DownloadItem] = [:]
    private var pollTimer: Timer?

    var hasActiveDownloads: Bool { items.contains { $0.state == .running } }

    /// Called from the web view delegates the moment WebKit turns a navigation into
    /// a download.
    func begin(_ download: WKDownload, suggestedName: String = "Download") {
        let item = DownloadItem(filename: suggestedName)
        item.download = download
        items.insert(item, at: 0)
        itemsByDownload[ObjectIdentifier(download)] = item
        download.delegate = self
        startPolling()
        notify()
    }

    func cancel(_ item: DownloadItem) {
        item.download?.cancel { _ in }
        item.state = .cancelled
        notify()
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
        notify()
    }

    func reveal(_ item: DownloadItem) {
        guard let destination = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    func open(_ item: DownloadItem) {
        guard let destination = item.destination, item.state == .finished else { return }
        NSWorkspace.shared.open(destination)
    }

    // MARK: - Progress polling

    /// WKDownload exposes an NSProgress; sampling it on a timer gives both the bar and
    /// a speed estimate without KVO churn on every packet.
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func sample() {
        var changed = false
        for item in items where item.state == .running {
            guard let progress = item.download?.progress else { continue }
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            if total > 0 { item.totalBytes = total }

            let now = Date()
            let elapsed = now.timeIntervalSince(item.lastSampleTime)
            if elapsed > 0.2 {
                let delta = Double(received - item.lastSampleBytes)
                let instant = max(0, delta / elapsed)
                // Exponential smoothing keeps the number readable instead of twitching.
                item.bytesPerSecond = item.bytesPerSecond == 0
                    ? instant : item.bytesPerSecond * 0.7 + instant * 0.3
                item.lastSampleBytes = received
                item.lastSampleTime = now
            }
            item.receivedBytes = received
            changed = true
        }
        if !hasActiveDownloads {
            pollTimer?.invalidate()
            pollTimer = nil
        }
        if changed { notify() }
    }

    private func notify() {
        NotificationCenter.default.post(name: .downloadsDidChange, object: nil)
    }

    // MARK: - Scanning

    private func scanIfNeeded(_ item: DownloadItem) {
        guard let destination = item.destination else { return }
        let size = max(item.totalBytes, item.receivedBytes)
        item.risk = DownloadRiskAssessor.assess(filename: item.filename, byteCount: size)

        guard DownloadRiskAssessor.shouldScan(risk: item.risk, policy: VirusTotal.policy) else {
            item.scan = .notRequested
            notify()
            return
        }
        guard VirusTotal.hasAPIKey else {
            item.scan = .unavailable("no API key")
            notify()
            return
        }
        item.scan = .working("Scanning…")
        notify()
        VirusTotal.scan(fileURL: destination, progress: { [weak self] stage in
            item.scan = .working(stage)
            self?.notify()
        }, completion: { [weak self] result in
            switch result {
            case .clean(let engines): item.scan = .clean(engines: engines)
            case .flagged(let malicious, let engines): item.scan = .flagged(malicious: malicious, engines: engines)
            case .unknownToVirusTotal: item.scan = .unknown
            case .failed(let message): item.scan = .unavailable(message)
            }
            self?.notify()
        })
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let item = itemsByDownload[ObjectIdentifier(download)]
        item?.filename = suggestedFilename
        if response.expectedContentLength > 0 {
            item?.totalBytes = response.expectedContentLength
        }

        let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var destination = downloadsDirectory.appendingPathComponent(suggestedFilename)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            destination = downloadsDirectory.appendingPathComponent(name)
            counter += 1
        }
        item?.destination = destination
        item?.risk = DownloadRiskAssessor.assess(filename: suggestedFilename,
                                                 byteCount: response.expectedContentLength)
        notify()
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = itemsByDownload[ObjectIdentifier(download)] else { return }
        item.state = .finished
        item.bytesPerSecond = 0
        if item.totalBytes == 0 { item.totalBytes = item.receivedBytes }
        itemsByDownload.removeValue(forKey: ObjectIdentifier(download))
        notify()
        scanIfNeeded(item)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = itemsByDownload[ObjectIdentifier(download)] else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            item.state = .cancelled
        } else {
            item.state = .failed(error.localizedDescription)
        }
        itemsByDownload.removeValue(forKey: ObjectIdentifier(download))
        notify()
    }
}
