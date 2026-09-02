import Foundation
import CryptoKit
import CommonCrypto
import LocalAuthentication

// MARK: - Secret containers

/// Bytes that are zeroed when released or wiped. Swift cannot promise the runtime made
/// no copies along the way, so this is a best effort that shortens how long a secret
/// lingers, not a guarantee. Hardened runtime is the real barrier.
final class SecureBytes {
    private(set) var bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }
    convenience init(_ data: Data) { self.init([UInt8](data)) }
    convenience init(_ key: SymmetricKey) { self.init(key.withUnsafeBytes { [UInt8]($0) }) }

    var count: Int { bytes.count }
    var isEmpty: Bool { bytes.isEmpty }
    /// A transient copy for APIs that need `Data`; callers drop it immediately.
    var data: Data { Data(bytes) }
    var symmetricKey: SymmetricKey { SymmetricKey(data: bytes) }

    func wipe() {
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return }
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }
        bytes.removeAll(keepingCapacity: false)
    }

    deinit { wipe() }
}

/// A password held as zeroable UTF-8. `withString` is the one place it becomes a
/// `String`, for the moment it takes to hand it to a text field or a page.
final class SecureString {
    private let storage: SecureBytes

    init(_ string: String) { storage = SecureBytes(Array(string.utf8)) }
    init(bytes: [UInt8]) { storage = SecureBytes(bytes) }

    var isEmpty: Bool { storage.isEmpty }

    func withString<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(String(decoding: storage.bytes, as: UTF8.self))
    }

    func wipe() { storage.wipe() }
}

// MARK: - Errors

enum VaultError: LocalizedError {
    case notSetUp
    case enclaveUnavailable
    case enclaveKeyUnusable
    case authenticationRequired
    case cancelled
    case authenticationFailed(Error?)
    case corrupt
    case wrongRecoveryKey
    case enclave(Error)
    case io(Error)

    var errorDescription: String? {
        switch self {
        case .notSetUp: return "Rocket Passwords hasn't been set up yet."
        case .enclaveUnavailable: return "Rocket Passwords needs a Mac with a Secure Enclave."
        case .enclaveKeyUnusable: return "This vault was created on another Mac. Restore it with your recovery key."
        case .authenticationRequired: return "Authentication is required."
        case .cancelled: return "Cancelled."
        case .authenticationFailed(let error): return error?.localizedDescription ?? "Authentication failed."
        case .corrupt: return "The password vault is damaged."
        case .wrongRecoveryKey: return "That recovery key doesn't open this vault."
        case .enclave(let error): return "Secure Enclave error: \(error.localizedDescription)"
        case .io(let error): return error.localizedDescription
        }
    }

    var isCancellation: Bool {
        if case .cancelled = self { return true }
        if case .authenticationFailed(let error?) = self, let la = error as? LAError,
           la.code == .userCancel || la.code == .appCancel || la.code == .systemCancel {
            return true
        }
        return false
    }
}

// MARK: - Recovery key

/// 160 random bits as Crockford base32 — no I, L, O or U, so a key read back from paper
/// decodes even when 0/O and 1/I/L were confused. Shown as 8 groups of 4.
enum RecoveryKey {
    static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let byteCount = 20
    static let characterCount = 32

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return encode(bytes)
    }

    static func encode(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == byteCount)
        var out: [Character] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 31)])
            }
        }
        var grouped = ""
        for (i, ch) in out.enumerated() {
            if i > 0 && i % 4 == 0 { grouped.append("-") }
            grouped.append(ch)
        }
        return grouped
    }

    /// Accepts any case, any separators, and the usual paper confusions.
    static func normalize(_ text: String) -> [UInt8]? {
        var symbols: [Int] = []
        for raw in text.uppercased() {
            var ch = raw
            switch ch {
            case "O": ch = "0"
            case "I", "L": ch = "1"
            case "-", " ", "\n", "\t", ".": continue
            default: break
            }
            guard let index = alphabet.firstIndex(of: ch) else { return nil }
            symbols.append(index)
        }
        guard symbols.count == characterCount else { return nil }
        var bytes: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for symbol in symbols {
            buffer = (buffer << 5) | UInt32(symbol)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return bytes.count == byteCount ? bytes : nil
    }
}

// MARK: - File format

struct EnclaveWrap: Codable {
    let keyBlob: Data
    let ephemeralPublicKey: Data
    let sealed: Data
}

struct RecoveryWrap: Codable {
    let salt: Data
    let iterations: Int
    let sealed: Data
}

/// The index: everything the UI lists without a prompt. Never holds a secret.
struct PasswordEntry: Codable, Equatable {
    let id: UUID
    /// Lowercased host, port kept when non-default ("localhost:3000").
    var host: String
    var url: String?
    var username: String
    var title: String?
    var created: Date
    var modified: Date
    var lastUsed: Date?

    init(id: UUID = UUID(), host: String, url: String? = nil, username: String, title: String? = nil,
         created: Date = Date(), modified: Date = Date(), lastUsed: Date? = nil) {
        self.id = id
        self.host = host
        self.url = url
        self.username = username
        self.title = title
        self.created = created
        self.modified = modified
        self.lastUsed = lastUsed
    }
}

struct PasswordSecret: Codable, Equatable {
    var password: String
    var notes: String?
    var otpAuth: String?
}

struct VaultIndex: Codable {
    var entries: [PasswordEntry] = []
}

/// Keyed by `uuidString`: a `[UUID: X]` dictionary encodes as a flat array in JSON.
struct VaultSecrets: Codable {
    var byID: [String: PasswordSecret] = [:]

    subscript(id: UUID) -> PasswordSecret? {
        get { byID[id.uuidString] }
        set { byID[id.uuidString] = newValue }
    }
}

struct VaultFile: Codable {
    static let currentVersion = 1

    let version: Int
    var gated: EnclaveWrap              // K, needs Touch ID / password
    var silent: EnclaveWrap             // Ki, this Mac only
    var recovery: RecoveryWrap          // K, under the recovery key
    var indexKeyUnderVaultKey: Data     // Ki sealed with K, so recovery restores the index
    var index: Data                     // VaultIndex sealed with Ki
    var secrets: Data                   // VaultSecrets sealed with K
    var modified: Date
}

/// Additional authenticated data per slot: a blob moved between slots fails to open.
enum VaultAAD {
    static let secrets = "rocket.vault.v1.secrets"
    static let index = "rocket.vault.v1.index"
    static let gated = "rocket.vault.v1.wrap.gated"
    static let silent = "rocket.vault.v1.wrap.silent"
    static let recovery = "rocket.vault.v1.wrap.recovery"
    static let indexKey = "rocket.vault.v1.indexkey"
}

// MARK: - Enclave

/// What the Secure Enclave provides, behind a protocol so the crypto path runs in a
/// harness with software keys.
protocol EnclaveProvider {
    var isAvailable: Bool { get }
    /// Creates a P-256 key agreement key; returns the opaque blob to persist.
    func makeKey(gated: Bool) throws -> Data
    /// Raw 64-byte public key. Never prompts.
    func publicKey(for blob: Data) throws -> Data
    /// ECDH with the enclave's private half. A gated key needs an authenticated context.
    func sharedSecret(blob: Data, ephemeralPublic: Data, context: LAContext?) throws -> SharedSecret
}

/// The real thing. CryptoKit's enclave keys need no entitlement (unlike the Security
/// framework's `kSecAttrTokenIDSecureEnclave`, which an ad-hoc-signed app cannot use):
/// the `dataRepresentation` blob is only usable by this Mac's enclave, and the access
/// control rides inside it, enforced at every use.
struct SecureEnclaveProvider: EnclaveProvider {
    var isAvailable: Bool { SecureEnclave.isAvailable }

    func makeKey(gated: Bool) throws -> Data {
        if gated {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.privateKeyUsage, .userPresence], &error) else {
                throw VaultError.enclave(error!.takeRetainedValue() as Error)
            }
            do { return try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access).dataRepresentation }
            catch { throw VaultError.enclave(error) }
        }
        do { return try SecureEnclave.P256.KeyAgreement.PrivateKey().dataRepresentation }
        catch { throw VaultError.enclave(error) }
    }

    func publicKey(for blob: Data) throws -> Data {
        // A context that forbids UI: reading the public half must never prompt.
        let quiet = LAContext()
        quiet.interactionNotAllowed = true
        guard let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob,
                                                                        authenticationContext: quiet) else {
            throw VaultError.enclaveKeyUnusable
        }
        return key.publicKey.rawRepresentation
    }

    func sharedSecret(blob: Data, ephemeralPublic: Data, context: LAContext?) throws -> SharedSecret {
        guard let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob,
                                                                        authenticationContext: context) else {
            throw VaultError.enclaveKeyUnusable
        }
        let peer: P256.KeyAgreement.PublicKey
        do { peer = try P256.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublic) }
        catch { throw VaultError.corrupt }
        do { return try key.sharedSecretFromKeyAgreement(with: peer) }
        catch let error as LAError where error.code == .userCancel || error.code == .appCancel {
            throw VaultError.cancelled
        } catch {
            throw VaultError.enclave(error)
        }
    }
}

// MARK: - Crypto

enum VaultCrypto {
    private static let wrapInfo = Data("rocket.vault.wrap".utf8)
    static let recoveryIterations = 1_000_000

    static func seal(_ plaintext: Data, key: SymmetricKey, aad: String) throws -> Data {
        do {
            let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(aad.utf8))
            guard let combined = box.combined else { throw VaultError.corrupt }
            return combined
        } catch { throw VaultError.corrupt }
    }

    static func open(_ combined: Data, key: SymmetricKey, aad: String) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key, authenticating: Data(aad.utf8))
        } catch { throw VaultError.corrupt }
    }

    /// ECIES-style: an ephemeral P-256 key agrees with the enclave key's public half;
    /// HKDF of that shared secret seals the payload. Only the enclave's private half
    /// can recompute it.
    static func wrap(_ secret: SymmetricKey, blob: Data, enclave: EnclaveProvider, aad: String) throws -> EnclaveWrap {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let enclavePublic: P256.KeyAgreement.PublicKey
        do { enclavePublic = try P256.KeyAgreement.PublicKey(rawRepresentation: try enclave.publicKey(for: blob)) }
        catch let error as VaultError { throw error }
        catch { throw VaultError.corrupt }
        let shared: SharedSecret
        do { shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclavePublic) }
        catch { throw VaultError.enclave(error) }
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation
        let wrapKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeralPublic,
                                                     sharedInfo: wrapInfo, outputByteCount: 32)
        let sealed = try seal(secret.withUnsafeBytes { Data($0) }, key: wrapKey, aad: aad)
        return EnclaveWrap(keyBlob: blob, ephemeralPublicKey: ephemeralPublic, sealed: sealed)
    }

    static func unwrap(_ wrap: EnclaveWrap, enclave: EnclaveProvider, context: LAContext?, aad: String) throws -> SymmetricKey {
        let shared = try enclave.sharedSecret(blob: wrap.keyBlob, ephemeralPublic: wrap.ephemeralPublicKey, context: context)
        let wrapKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: wrap.ephemeralPublicKey,
                                                     sharedInfo: wrapInfo, outputByteCount: 32)
        return SymmetricKey(data: try open(wrap.sealed, key: wrapKey, aad: aad))
    }

    static func deriveKEK(recoveryKeyBytes: [UInt8], salt: Data, iterations: Int) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        let status = recoveryKeyBytes.withUnsafeBufferPointer { password -> Int32 in
            password.baseAddress!.withMemoryRebound(to: CChar.self, capacity: password.count) { passwordChars in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordChars, password.count,
                                     saltBytes, saltBytes.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     &out, out.count)
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return SymmetricKey(data: out)
    }

    static func sealRecovery(_ secret: SymmetricKey, recoveryKeyBytes: [UInt8],
                             iterations: Int = recoveryIterations) throws -> RecoveryWrap {
        var salt = [UInt8](repeating: 0, count: 16)
        for i in salt.indices { salt[i] = UInt8.random(in: 0...255) }
        let kek = deriveKEK(recoveryKeyBytes: recoveryKeyBytes, salt: Data(salt), iterations: iterations)
        let sealed = try seal(secret.withUnsafeBytes { Data($0) }, key: kek, aad: VaultAAD.recovery)
        return RecoveryWrap(salt: Data(salt), iterations: iterations, sealed: sealed)
    }

    static func openRecovery(_ wrap: RecoveryWrap, recoveryKeyBytes: [UInt8]) throws -> SymmetricKey {
        let kek = deriveKEK(recoveryKeyBytes: recoveryKeyBytes, salt: wrap.salt, iterations: wrap.iterations)
        do { return SymmetricKey(data: try open(wrap.sealed, key: kek, aad: VaultAAD.recovery)) }
        catch { throw VaultError.wrongRecoveryKey }
    }

    // MARK: JSON

    /// Sorted keys, so "did the body change anything" is a byte comparison.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw VaultError.corrupt }
    }
}
