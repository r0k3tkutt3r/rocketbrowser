import Foundation

/// Splits one large HTTP download across several parallel byte-range requests.
///
/// The stream count is not a guess. Measured against a transatlantic host from this
/// machine: 2.19x at four connections, no meaningful gain at eight, and a *regression*
/// to 1.05x at sixteen — past a handful of connections the origin starts refusing them
/// per IP. Four is the knee; raising it makes downloads slower, not faster.
///
/// Every chunk gets its OWN `URLSession` deliberately. URLSession pools connections per
/// session, so sharing one would let HTTP/2 multiplex all four range requests onto a
/// single TCP connection, where they share one congestion window — and the entire
/// exercise gains nothing. Separate sessions force separate connections.
final class ChunkedDownload {

    static let streamCount = 4

    /// Below this the extra round trips and the risk of leaving the WebKit path aren't
    /// worth it. Deliberately well above the 25 MB VirusTotal scanning floor.
    static let minimumSize: Int64 = 50 * 1024 * 1024

    fileprivate static let maximumRetriesPerChunk = 2

    /// Mirrors `applicationNameForUserAgent` in `BrowserWindowController`. Used only if
    /// WebKit's own request didn't carry a UA; some hosts reject the stock WKWebView one.
    static let fallbackUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "ChunkedDownloads") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ChunkedDownloads") }
    }

    enum Outcome {
        case finished
        case failed(String)
        case cancelled
    }

    /// Inclusive on both ends, matching HTTP's `Range: bytes=start-end`.
    struct ByteRange: Equatable {
        let start: Int64
        let end: Int64
        var length: Int64 { end - start + 1 }
    }

    // MARK: - Pure helpers
    //
    // Everything in this section is free of UI, network and singleton dependencies so it
    // can be exercised with the repo's swiftc assert-harness pattern.

    /// Contiguous, gapless cover of `0..<totalBytes`. Remainder bytes are spread over the
    /// leading chunks rather than dumped on the last one, so no single chunk lags.
    static func split(totalBytes: Int64, into count: Int) -> [ByteRange] {
        guard totalBytes > 0 else { return [] }
        let chunks = min(Int64(max(1, count)), totalBytes)
        let base = totalBytes / chunks
        let remainder = totalBytes % chunks
        var ranges: [ByteRange] = []
        var cursor: Int64 = 0
        for index in 0..<chunks {
            let length = base + (index < remainder ? 1 : 0)
            ranges.append(ByteRange(start: cursor, end: cursor + length - 1))
            cursor += length
        }
        return ranges
    }

    /// `bytes 0-0/1073741824` -> 1073741824. A `*` total means the server won't say.
    static func totalBytes(fromContentRange value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        let tail = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return Int64(tail)
    }

    /// Per-chunk completion in 0...1, positionally matched to the ranges. A chunk with no
    /// length reads as 0 rather than dividing by zero.
    static func fractions(received: [Int64], lengths: [Int64]) -> [Double] {
        zip(received, lengths).map { received, length in
            length > 0 ? min(1, max(0, Double(received) / Double(length))) : 0
        }
    }

    static func supportsRanges(header: String?) -> Bool {
        guard let header else { return false }
        return header.lowercased().contains("bytes")
    }

    /// Whether it's worth *trying* to chunk this response. Says nothing about whether the
    /// server will honour a range request — only `probe` establishes that.
    static func isEligible(response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        guard let scheme = http.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        // A content-coded body means Content-Length describes the *encoded* stream while
        // WebKit hands the decoded one to disk. Don't try to reconcile the two.
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespaces).lowercased(),
           !encoding.isEmpty, encoding != "identity" { return false }
        guard http.expectedContentLength >= minimumSize else { return false }
        return supportsRanges(header: http.value(forHTTPHeaderField: "Accept-Ranges"))
    }

    /// Cookies must be carried over by hand: leaving WKDownload means leaving the
    /// WKWebsiteDataStore that was authenticating the request.
    static func cookieHeader(for url: URL, from cookies: [HTTPCookie], now: Date = Date()) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let isSecure = url.scheme?.lowercased() == "https"
        let matching = cookies.filter { cookie in
            if cookie.isSecure && !isSecure { return false }
            if let expires = cookie.expiresDate, expires < now { return false }
            var domain = cookie.domain.lowercased()
            if domain.hasPrefix(".") {
                domain.removeFirst()
                guard host == domain || host.hasSuffix("." + domain) else { return false }
            } else if host != domain {
                return false
            }
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            guard cookiePath == "/" || path == cookiePath
                    || path.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")
            else { return false }
            return true
        }
        guard !matching.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }

    /// Confirms the server really honours ranges, and returns the authoritative size.
    ///
    /// This is also the safety valve for the whole feature: a one-time signed URL that has
    /// already been consumed answers 403 here, so the caller keeps the live WKDownload
    /// instead of cancelling it for a re-fetch that would fail.
    static func probe(url: URL, headers: [String: String], completion: @escaping (Int64?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.timeoutInterval = 20

        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { _, response, error in
            session.finishTasksAndInvalidate()
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 206,
                  let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                  let total = totalBytes(fromContentRange: contentRange) else {
                completion(nil)
                return
            }
            completion(total)
        }.resume()
    }

    // MARK: - Instance

    private let url: URL
    private let destination: URL
    private let partURL: URL
    let totalBytes: Int64
    private let headers: [String: String]

    private var workers: [ChunkWorker] = []
    private var expectedWorkers = 0
    private var finishedWorkers = 0
    private var failureMessage: String?
    private var isCancelled = false
    private var completion: ((Outcome) -> Void)?

    private let lock = NSLock()
    private var storedReceivedBytes: Int64 = 0
    private var chunkReceived: [Int64] = []
    private var chunkLengths: [Int64] = []

    /// Read from the main thread by the downloads poll timer while workers write from
    /// their own delegate queues.
    var receivedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return storedReceivedBytes
    }

    /// What the downloads panel draws as the split bar. Empty until `start` runs.
    var chunkFractions: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return Self.fractions(received: chunkReceived, lengths: chunkLengths)
    }

    init(url: URL, destination: URL, totalBytes: Int64, headers: [String: String]) {
        self.url = url
        self.destination = destination
        // Write to a sidecar so a failure never leaves a full-size sparse file sitting in
        // ~/Downloads looking like a finished download.
        self.partURL = destination.appendingPathExtension("rocketpart")
        self.totalBytes = totalBytes
        self.headers = headers
    }

    func start(completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        let ranges = Self.split(totalBytes: totalBytes, into: Self.streamCount)
        guard !ranges.isEmpty else {
            finish(.failed("Empty download"))
            return
        }

        // Pre-allocate the whole file so every worker can seek straight to its own offset.
        // Each worker then opens its own descriptor: separate descriptors carry independent
        // file offsets, which is what makes the concurrent writes safe with no lock.
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: partURL)
            try handle.truncate(atOffset: UInt64(totalBytes))
            try handle.close()
        } catch {
            finish(.failed(error.localizedDescription))
            return
        }

        expectedWorkers = ranges.count
        lock.lock()
        chunkLengths = ranges.map(\.length)
        chunkReceived = Array(repeating: 0, count: ranges.count)
        lock.unlock()
        workers = ranges.enumerated().map { index, range in
            ChunkWorker(url: url, partURL: partURL, range: range, headers: headers,
                        onBytes: { [weak self] delta in self?.addBytes(delta, chunk: index) },
                        onFinish: { [weak self] error in self?.workerFinished(error) })
        }
        workers.forEach { $0.start() }
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        teardown()
        try? FileManager.default.removeItem(at: partURL)
        finish(.cancelled)
    }

    private func addBytes(_ delta: Int64, chunk index: Int) {
        lock.lock()
        storedReceivedBytes += delta
        if index < chunkReceived.count { chunkReceived[index] += delta }
        lock.unlock()
    }

    private func workerFinished(_ error: Error?) {
        // Workers report from four different delegate queues; funnel them onto main so the
        // counters and the completion decision stay single-threaded.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCancelled, self.completion != nil else { return }
            if let error, self.failureMessage == nil {
                self.failureMessage = error.localizedDescription
            }
            self.finishedWorkers += 1
            guard self.finishedWorkers == self.expectedWorkers else { return }
            self.teardown()

            if let message = self.failureMessage {
                try? FileManager.default.removeItem(at: self.partURL)
                self.finish(.failed(message))
                return
            }
            do {
                if FileManager.default.fileExists(atPath: self.destination.path) {
                    try FileManager.default.removeItem(at: self.destination)
                }
                try FileManager.default.moveItem(at: self.partURL, to: self.destination)
            } catch {
                try? FileManager.default.removeItem(at: self.partURL)
                self.finish(.failed(error.localizedDescription))
                return
            }
            self.finish(.finished)
        }
    }

    private func teardown() {
        workers.forEach { $0.stop() }
        workers.removeAll()
    }

    private func finish(_ outcome: Outcome) {
        let handler = completion
        completion = nil
        handler?(outcome)
    }
}

/// One range request, its own connection, its own file descriptor.
private final class ChunkWorker: NSObject, URLSessionDataDelegate {

    private let url: URL
    private let partURL: URL
    private let range: ChunkedDownload.ByteRange
    private let headers: [String: String]
    private let onBytes: (Int64) -> Void
    private let onFinish: (Error?) -> Void

    private var session: URLSession?
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var retries = 0
    private var stopped = false
    private var refusalReason: String?

    init(url: URL, partURL: URL, range: ChunkedDownload.ByteRange, headers: [String: String],
         onBytes: @escaping (Int64) -> Void, onFinish: @escaping (Error?) -> Void) {
        self.url = url
        self.partURL = partURL
        self.range = range
        self.headers = headers
        self.onBytes = onBytes
        self.onFinish = onFinish
        super.init()
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        resume()
    }

    func stop() {
        stopped = true
        session?.invalidateAndCancel()
        session = nil
        try? handle?.close()
        handle = nil
    }

    /// Also the retry path: picks up from whatever this chunk already wrote, so a dropped
    /// connection costs the remainder of one chunk rather than the whole file.
    private func resume() {
        guard !stopped, let session else { return }
        try? handle?.close()
        handle = nil

        let start = range.start + written
        guard start <= range.end else {
            onFinish(nil)
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: partURL)
            try handle.seek(toOffset: UInt64(start))
            self.handle = handle
        } catch {
            onFinish(error)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(range.end)", forHTTPHeaderField: "Range")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        session.dataTask(with: request).resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // Anything but 206 means the server stopped honouring the range mid-flight; a 200
        // would restart the whole body at offset zero and silently corrupt the file.
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            refusalReason = "Server refused range request (HTTP \(code))"
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped, let handle else { return }
        let remaining = range.length - written
        guard remaining > 0 else { return }
        // Clamp: a server that ignores the range end must not be allowed to write over the
        // next chunk's territory.
        let payload = Int64(data.count) <= remaining ? data : data.prefix(Int(remaining))
        do {
            try handle.write(contentsOf: payload)
            written += Int64(payload.count)
            onBytes(Int64(payload.count))
        } catch {
            refusalReason = error.localizedDescription
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped else { return }
        try? handle?.close()
        handle = nil

        if let reason = refusalReason {
            onFinish(NSError(domain: "Rocket", code: 1,
                             userInfo: [NSLocalizedDescriptionKey: reason]))
            return
        }
        if error == nil, written >= range.length {
            onFinish(nil)
            return
        }
        if retries < ChunkedDownload.maximumRetriesPerChunk {
            retries += 1
            resume()
            return
        }
        onFinish(error ?? NSError(domain: "Rocket", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Connection ended early"]))
    }
}
