import CryptoKit
import Foundation

/// How much of a download is worth scanning.
enum ScanPolicy: String {
    case off
    case riskyOrLarge   // executables, installers, archives, scripts, or big files
    case everything
}

/// What the browser decided about a file before any network call.
enum DownloadRisk: String {
    case benign
    case large
    case risky

    var label: String {
        switch self {
        case .benign: return "ordinary file"
        case .large: return "large file"
        case .risky: return "executable or archive"
        }
    }
}

enum DownloadRiskAssessor {

    /// Anything macOS can run, mount, or unpack into something runnable. These are file
    /// *types*, not a blocklist of sites — the categories are what make a download risky.
    static let riskyExtensions: Set<String> = [
        // macOS executables and installers
        "app", "dmg", "pkg", "mpkg", "command", "workflow", "scpt", "scptd", "dylib", "kext",
        // cross-platform executables
        "exe", "msi", "bat", "cmd", "com", "scr", "vbs", "ps1", "jar", "apk", "deb", "rpm", "appimage", "msix",
        // scripts
        "sh", "zsh", "bash", "py", "pl", "rb", "php",
        // archives (a container hides whatever is inside from inspection)
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "iso", "cab",
        // macro-capable documents
        "docm", "xlsm", "pptm", "dotm", "xlam",
    ]

    /// Big enough that a bad file is worth a check even when the type looks dull.
    static let largeFileThreshold: Int64 = 25 * 1024 * 1024

    static func assess(filename: String, byteCount: Int64) -> DownloadRisk {
        let ext = (filename as NSString).pathExtension.lowercased()
        if riskyExtensions.contains(ext) { return .risky }
        // No extension at all is a classic way to smuggle a Mach-O binary past a glance.
        if ext.isEmpty && byteCount > 0 { return .risky }
        if byteCount >= largeFileThreshold { return .large }
        return .benign
    }

    static func shouldScan(risk: DownloadRisk, policy: ScanPolicy) -> Bool {
        switch policy {
        case .off: return false
        case .everything: return true
        case .riskyOrLarge: return risk != .benign
        }
    }
}

/// Minimal VirusTotal v3 client. Looking a file up sends only its SHA-256 — the file
/// itself never leaves the Mac unless `uploadsUnknownFiles` is explicitly turned on,
/// because uploading hands a copy of your file to a third party permanently.
enum VirusTotal {

    private static let service = "com.kushmodi.rocket.virustotal"
    private static let account = "api-key"
    /// VirusTotal's simple upload endpoint tops out here; bigger files need a
    /// one-shot upload URL.
    private static let simpleUploadLimit: Int64 = 32 * 1024 * 1024

    enum Result {
        case clean(engines: Int)
        case flagged(malicious: Int, engines: Int)
        case unknownToVirusTotal
        case failed(String)
    }

    // MARK: - Settings

    static var policy: ScanPolicy {
        get { ScanPolicy(rawValue: UserDefaults.standard.string(forKey: "VTScanPolicy") ?? "") ?? .riskyOrLarge }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "VTScanPolicy") }
    }

    /// Off by default on purpose: a lookup reveals a hash, an upload reveals the file.
    static var uploadsUnknownFiles: Bool {
        get { UserDefaults.standard.bool(forKey: "VTUploadUnknownFiles") }
        set { UserDefaults.standard.set(newValue, forKey: "VTUploadUnknownFiles") }
    }

    static var hasAPIKey: Bool { apiKey?.isEmpty == false }

    /// A plain-text file holding the key, for people who would rather keep it in the
    /// project than type it into a dialog. The file stays the source of truth; its
    /// contents are copied into the keychain at every launch so the rest of the app
    /// only ever reads from the keychain.
    static var keyFilePath: String? {
        get { UserDefaults.standard.string(forKey: "VTKeyFilePath") }
        set { UserDefaults.standard.set(newValue, forKey: "VTKeyFilePath") }
    }

    /// Filenames probed inside Application Support when no explicit path is set.
    private static let conventionalKeyFilenames = ["virustotalkey.txt", "virustotalapikey.txt"]

    /// Called at launch. A key file always wins over the stored copy, so editing the
    /// file and relaunching is enough to rotate the key.
    @discardableResult
    static func importKeyFromFileIfAvailable() -> Bool {
        var candidates: [URL] = []
        if let keyFilePath, !keyFilePath.isEmpty {
            candidates.append(URL(fileURLWithPath: keyFilePath))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rocket", isDirectory: true)
        candidates.append(contentsOf: conventionalKeyFilenames.map { support.appendingPathComponent($0) })

        for candidate in candidates {
            guard let contents = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            let key = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if apiKey != key { apiKey = key }
            return true
        }
        return false
    }

    // MARK: - Keychain-backed API key

    static var apiKey: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty, let data = newValue.data(using: .utf8) else { return }
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: - Hashing

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Scanning

    /// Hash lookup first; only uploads when the hash is unknown *and* the user opted in.
    static func scan(fileURL: URL,
                     progress: @escaping (String) -> Void,
                     completion: @escaping (Result) -> Void) {
        guard let key = apiKey, !key.isEmpty else {
            completion(.failed("No API key set"))
            return
        }
        progress("Hashing…")
        DispatchQueue.global(qos: .utility).async {
            guard let hash = sha256(of: fileURL) else {
                DispatchQueue.main.async { completion(.failed("Could not read file")) }
                return
            }
            DispatchQueue.main.async { progress("Checking VirusTotal…") }
            lookup(hash: hash, key: key) { result in
                if case .unknownToVirusTotal = result, uploadsUnknownFiles {
                    upload(fileURL: fileURL, key: key, progress: progress, completion: completion)
                } else {
                    completion(result)
                }
            }
        }
    }

    private static func request(_ url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-apikey")
        request.timeoutInterval = 30
        return request
    }

    private static func lookup(hash: String, key: String, completion: @escaping (Result) -> Void) {
        let url = URL(string: "https://www.virustotal.com/api/v3/files/\(hash)")!
        URLSession.shared.dataTask(with: request(url, key: key)) { data, response, error in
            DispatchQueue.main.async {
                completion(interpret(data: data, response: response, error: error))
            }
        }.resume()
    }

    private static func interpret(data: Data?, response: URLResponse?, error: Error?) -> Result {
        if let error { return .failed(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { return .failed("No response") }
        switch http.statusCode {
        case 200:
            guard let data, let stats = analysisStats(from: data) else { return .failed("Unreadable response") }
            let malicious = (stats["malicious"] ?? 0) + (stats["suspicious"] ?? 0)
            let engines = stats.values.reduce(0, +)
            return malicious > 0 ? .flagged(malicious: malicious, engines: engines) : .clean(engines: engines)
        case 404: return .unknownToVirusTotal
        case 401: return .failed("API key rejected")
        case 429: return .failed("Rate limit reached")
        default: return .failed("HTTP \(http.statusCode)")
        }
    }

    /// Pulls last_analysis_stats out of either a /files or an /analyses response.
    private static func analysisStats(from data: Data) -> [String: Int]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObject = root["data"] as? [String: Any],
              let attributes = dataObject["attributes"] as? [String: Any] else { return nil }
        if let stats = attributes["last_analysis_stats"] as? [String: Int] { return stats }
        if let stats = attributes["stats"] as? [String: Int] { return stats }
        return nil
    }

    // MARK: - Upload (opt-in only)

    private static func upload(fileURL: URL, key: String,
                               progress: @escaping (String) -> Void,
                               completion: @escaping (Result) -> Void) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        DispatchQueue.main.async { progress("Uploading…") }

        // Files past the simple limit need a dedicated upload URL from the API.
        if size > simpleUploadLimit {
            let url = URL(string: "https://www.virustotal.com/api/v3/files/upload_url")!
            URLSession.shared.dataTask(with: request(url, key: key)) { data, _, error in
                guard let data,
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let endpoint = root["data"] as? String, let target = URL(string: endpoint) else {
                    DispatchQueue.main.async {
                        completion(.failed(error?.localizedDescription ?? "Could not get upload URL"))
                    }
                    return
                }
                postFile(fileURL: fileURL, to: target, key: key, progress: progress, completion: completion)
            }.resume()
            return
        }
        postFile(fileURL: fileURL, to: URL(string: "https://www.virustotal.com/api/v3/files")!,
                 key: key, progress: progress, completion: completion)
    }

    private static func postFile(fileURL: URL, to endpoint: URL, key: String,
                                 progress: @escaping (String) -> Void,
                                 completion: @escaping (Result) -> Void) {
        guard let fileData = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            DispatchQueue.main.async { completion(.failed("Could not read file")) }
            return
        }
        let boundary = "rocket-\(UUID().uuidString)"
        var request = self.request(endpoint, key: key)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
            .data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObject = root["data"] as? [String: Any],
                  let analysisID = dataObject["id"] as? String else {
                DispatchQueue.main.async {
                    completion(.failed(error?.localizedDescription ?? "Upload failed"))
                }
                return
            }
            DispatchQueue.main.async { progress("Analyzing…") }
            pollAnalysis(id: analysisID, key: key, attempt: 1, completion: completion)
        }.resume()
    }

    /// VirusTotal analyses are asynchronous; poll with a ceiling so a stuck job can't
    /// spin forever.
    private static func pollAnalysis(id: String, key: String, attempt: Int,
                                     completion: @escaping (Result) -> Void) {
        guard attempt <= 20 else {
            DispatchQueue.main.async { completion(.failed("Analysis still running")) }
            return
        }
        let url = URL(string: "https://www.virustotal.com/api/v3/analyses/\(id)")!
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            URLSession.shared.dataTask(with: request(url, key: key)) { data, response, error in
                guard let data,
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataObject = root["data"] as? [String: Any],
                      let attributes = dataObject["attributes"] as? [String: Any],
                      let status = attributes["status"] as? String else {
                    DispatchQueue.main.async {
                        completion(interpret(data: data, response: response, error: error))
                    }
                    return
                }
                if status == "completed" {
                    DispatchQueue.main.async {
                        completion(interpret(data: data, response: response, error: error))
                    }
                } else {
                    pollAnalysis(id: id, key: key, attempt: attempt + 1, completion: completion)
                }
            }.resume()
        }
    }
}
