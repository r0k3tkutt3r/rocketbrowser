import CommonCrypto
import Foundation
import Security
import SQLite3

struct ChromeProfile: Equatable {
    /// Directory name under Chrome's support folder ("Default", "Profile 1").
    var directory: String
    var displayName: String
}

enum ChromeImportError: Error, Equatable {
    case notInstalled
    case keychainDenied
    case unreadable(String)
}

/// Reads logins straight from Chrome's own files: SQLite for the rows, the "Chrome Safe
/// Storage" keychain item for the key. Reading that item raises the macOS consent
/// dialog, so `read` blocks and belongs off the main thread.
enum ChromeImport {

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Google/Chrome")
    }

    private static let loginFiles = ["Login Data", "Login Data For Account"]

    static func profiles() -> [ChromeProfile] {
        profiles(in: root)
    }

    static func profiles(in root: URL) -> [ChromeProfile] {
        let fm = FileManager.default
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (dir, info) in cache {
                if let name = (info as? [String: Any])?["name"] as? String { names[dir] = name }
            }
        }
        let dirs = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return dirs.sorted().compactMap { dir in
            let has = loginFiles.contains { fm.fileExists(atPath: root.appendingPathComponent(dir).appendingPathComponent($0).path) }
            return has ? ChromeProfile(directory: dir, displayName: names[dir] ?? dir) : nil
        }
    }

    static func read(profiles: [ChromeProfile]) throws -> ImportResult {
        guard FileManager.default.fileExists(atPath: root.path) else { throw ChromeImportError.notInstalled }
        let password = try safeStoragePassword()
        var key = deriveKey(safeStoragePassword: password)
        defer { wipe(&key) }
        return try read(profiles: profiles, in: root, key: key)
    }

    /// Split from `read` so a harness can supply its own root and key without the keychain.
    static func read(profiles: [ChromeProfile], in root: URL, key: Data) throws -> ImportResult {
        var credentials: [ImportedCredential] = []
        var seen = Set<String>()
        var unreadable = 0
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("rocket-chrome-\(UUID().uuidString)")
        do { try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw ChromeImportError.unreadable(error.localizedDescription) }
        // The copies hold Chrome's encrypted passwords; never leave them behind.
        defer { try? fm.removeItem(at: temp) }

        for (index, profile) in profiles.enumerated() {
            for name in loginFiles {
                let source = root.appendingPathComponent(profile.directory).appendingPathComponent(name)
                guard fm.fileExists(atPath: source.path) else { continue }
                let copy = temp.appendingPathComponent("\(index)-\(name.replacingOccurrences(of: " ", with: "_"))")
                do {
                    try fm.copyItem(at: source, to: copy)
                    // Chrome holds the database open, so recent rows may live only in the WAL.
                    let wal = URL(fileURLWithPath: source.path + "-wal")
                    if fm.fileExists(atPath: wal.path) { try fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal")) }
                } catch {
                    throw ChromeImportError.unreadable("\(profile.displayName): \(error.localizedDescription)")
                }
                try rows(in: copy, key: key, into: &credentials, seen: &seen, unreadable: &unreadable)
            }
        }
        return ImportResult(credentials: credentials, unreadableRows: unreadable)
    }

    private static func rows(in db: URL, key: Data, into credentials: inout [ImportedCredential],
                             seen: inout Set<String>, unreadable: inout Int) throws {
        var handle: OpaquePointer?
        // Not read-only: a WAL can only be replayed by a connection that may write the
        // shm file, and this is a private copy anyway.
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw ChromeImportError.unreadable("cannot open \(db.lastPathComponent)")
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT origin_url, action_url, username_value, password_value, blacklisted_by_user FROM logins"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ChromeImportError.unreadable(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            if sqlite3_column_int(statement, 4) != 0 { continue }
            let origin = text(0)
            guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", let host = SiteMatcher.host(from: url) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 3))
            guard length > 0, let bytes = sqlite3_column_blob(statement, 3),
                  let password = decrypt(Data(bytes: bytes, count: length), key: key), !password.isEmpty else {
                unreadable += 1
                continue
            }
            let username = text(2)
            guard seen.insert("\(host)\u{0}\(username)\u{0}\(password)").inserted else { continue }
            credentials.append(ImportedCredential(host: host, url: origin, username: username,
                                                  password: password, title: nil, notes: nil, otpAuth: nil))
        }
    }

    // MARK: Crypto

    static func deriveKey(safeStoragePassword: String) -> Data {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let password = Array(safeStoragePassword.utf8)
        _ = password.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: Int8.self, capacity: password.count) { pw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, password.count, salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
            }
        }
        defer { for i in key.indices { key[i] = 0 } }
        return Data(key)
    }

    static func decrypt(_ blob: Data, key: Data) -> String? {
        guard key.count == kCCKeySizeAES128, blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
        let body = blob.dropFirst(3)
        guard !body.isEmpty, body.count % kCCBlockSizeAES128 == 0 else { return nil }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var moved = 0
        let status = key.withUnsafeBytes { k in
            body.withUnsafeBytes { b in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, key.count, iv, b.baseAddress, body.count, &out, out.count, &moved)
            }
        }
        guard status == kCCSuccess else { return nil }
        let plain = Data(out.prefix(moved))
        if let s = String(data: plain, encoding: .utf8) { return s }
        // Newer builds prefix a SHA-256 of the domain to the plaintext.
        if plain.count > 32 { return String(data: plain.dropFirst(32), encoding: .utf8) }
        return nil
    }

    private static func safeStoragePassword() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
                throw ChromeImportError.unreadable("unexpected keychain item")
            }
            return text
        case errSecItemNotFound: throw ChromeImportError.notInstalled
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: throw ChromeImportError.keychainDenied
        case let status: throw ChromeImportError.unreadable("keychain error \(status)")
        }
    }

    private static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) }
    }
}
