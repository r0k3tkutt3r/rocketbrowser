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
    case tampered
    case wrongRecoveryKey
    case enclave(Error)
    case io(Error)

    var errorDescription: String? {
        switch self {
        case .notSetUp: return "Rocket Passwords hasn't been set up yet."
        case .enclaveUnavailable: return "Rocket Passwords needs a Mac with a Secure Enclave."
        case .enclaveKeyUnusable: return "This vault needs your recovery key. It came from another Mac, uses an older format, or was changed outside Rocket."
        case .authenticationRequired: return "Authentication is required."
        case .cancelled: return "Cancelled."
        case .authenticationFailed(let error): return error?.localizedDescription ?? "Authentication failed."
        case .corrupt: return "The password vault is damaged."
        case .tampered: return "The password vault was changed outside Rocket, so nothing was opened or saved. Restore it with your recovery key."
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

    /// Accepts any case, any separators, and the usual paper confusions. The separator
    /// set is generous on purpose: a key copied out of a document arrives with the
    /// dashes a word processor substituted and whatever line endings it used, and
    /// rejecting that reads to the user as "your recovery key is wrong".
    static func normalize(_ text: String) -> [UInt8]? {
        // Scalars, not Characters: "\r\n" is a single grapheme cluster, so a key pasted
        // with Windows line endings would match neither "\r" nor "\n" on its own.
        let separators: Set<Unicode.Scalar> = [
            "-", " ", "\n", "\r", "\t", ".", "_", "/", "|", ",",
            "\u{00A0}",                                     // non-breaking space
            "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", // hyphen, non-breaking, figure, en dash
            "\u{2014}", "\u{2015}", "\u{2212}",             // em dash, horizontal bar, minus sign
            "\u{200B}", "\u{FEFF}",                         // zero-width space, BOM
        ]
        var symbols: [Int] = []
        for scalar in text.uppercased().unicodeScalars {
            if separators.contains(scalar) { continue }
            var ch = Character(scalar)
            switch ch {
            case "O": ch = "0"
            case "I", "L": ch = "1"
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

/// A WebAuthn credential Rocket created and holds itself. Everything here is public
/// to the relying party anyway, so it lives in the index and the sign-in sheet can list
/// accounts without a prompt; the private key is in `VaultSecrets.passkeyKeys`.
struct PasskeyEntry: Codable, Equatable {
    let id: UUID
    /// The relying party id the credential is scoped to ("github.com"), lowercased.
    let rpID: String
    let credentialID: Data
    /// `user.id` as the site sent it. Returned with every assertion.
    let userHandle: Data
    var userName: String
    var displayName: String?
    let created: Date
    var lastUsed: Date?
}

/// Both containers decode their newer keys with `decodeIfPresent`: a vault written
/// before passkeys existed has no `passkeys` key, and the synthesized decoder would
/// reject it as corrupt.
struct VaultIndex: Codable, Equatable {
    var entries: [PasswordEntry] = []
    var passkeys: [PasskeyEntry] = []

    init(entries: [PasswordEntry] = [], passkeys: [PasskeyEntry] = []) {
        self.entries = entries
        self.passkeys = passkeys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([PasswordEntry].self, forKey: .entries)
        passkeys = try container.decodeIfPresent([PasskeyEntry].self, forKey: .passkeys) ?? []
    }

    /// What `VaultSecrets.sealedIndex` holds. `lastUsed` is left out because `markUsed`
    /// writes it with no key in hand, which is the whole reason the index can be touched
    /// without a prompt.
    var withoutUsage: VaultIndex {
        var copy = self
        for i in copy.entries.indices { copy.entries[i].lastUsed = nil }
        for i in copy.passkeys.indices { copy.passkeys[i].lastUsed = nil }
        return copy
    }
}

/// Keyed by `uuidString`: a `[UUID: X]` dictionary encodes as a flat array in JSON.
struct VaultSecrets: Codable {
    var byID: [String: PasswordSecret] = [:]
    /// P-256 signing keys (raw 32-byte scalars) by `PasskeyEntry.id`.
    var passkeyKeys: [String: Data] = [:]
    /// The authoritative copy of the index. `VaultFile.index` opens with a key any local
    /// process can use without a prompt, so it can be rewritten to point a saved password
    /// at another site. Every open compares the two before anything is released.
    var sealedIndex: VaultIndex?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        byID = try container.decode([String: PasswordSecret].self, forKey: .byID)
        passkeyKeys = try container.decodeIfPresent([String: Data].self, forKey: .passkeyKeys) ?? [:]
        sealedIndex = try container.decodeIfPresent(VaultIndex.self, forKey: .sealedIndex)
    }

    subscript(id: UUID) -> PasswordSecret? {
        get { byID[id.uuidString] }
        set { byID[id.uuidString] = newValue }
    }
}

struct VaultFile: Codable {
    /// Version 1 wrapped K to the gated key's public half, which anyone can do. It opens
    /// only through `restore`: accepting it elsewhere would let a forged file claim to
    /// be old.
    static let currentVersion = 2

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
    /// True when the key answers with no authentication at all. Never prompts. A gated
    /// slot holding such a key is a planted one.
    func usableWithoutPresence(blob: Data) -> Bool
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

    func usableWithoutPresence(blob: Data) -> Bool {
        let quiet = LAContext()
        quiet.interactionNotAllowed = true
        return (try? sharedSecret(blob: blob, ephemeralPublic: VaultCrypto.gatedPeer, context: quiet)) != nil
    }
}

// MARK: - Crypto

enum VaultCrypto {
    private static let wrapInfo = Data("rocket.vault.wrap".utf8)
    private static let gatedWrapInfo = Data("rocket.vault.wrap.gated.v2".utf8)
    /// The public half of a P-256 key whose private half was discarded the moment it was
    /// generated. Only the gated key's private half can agree with this point, so unlike
    /// `wrap`, a gated wrap cannot be made from public data: writing one takes the same
    /// authentication as reading one. It is a constant and never read from the file,
    /// because a peer stored in the file is a peer an attacker chooses.
    static let gatedPeer = Data((0..<64).map { i -> UInt8 in
        let hex = Array("7ccba91214e40984e05ae3cd9d9ad7dc18d8532a11daf80daef3e913ea1ac8f4efca3fdc49ef4de0b8b78b308efe88297be707049e276a1fbd7d5f7ccd8af375".utf8)
        func nibble(_ c: UInt8) -> UInt8 { c >= 97 ? c - 87 : c - 48 }
        return nibble(hex[i * 2]) << 4 | nibble(hex[i * 2 + 1])
    })
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

    private static func gatedWrapKey(blob: Data, enclave: EnclaveProvider, context: LAContext?) throws -> SymmetricKey {
        try enclave.sharedSecret(blob: blob, ephemeralPublic: gatedPeer, context: context)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: gatedPeer,
                                     sharedInfo: gatedWrapInfo, outputByteCount: 32)
    }

    static func wrapGated(_ secret: SymmetricKey, blob: Data, enclave: EnclaveProvider, context: LAContext?) throws -> EnclaveWrap {
        let key = try gatedWrapKey(blob: blob, enclave: enclave, context: context)
        let sealed = try seal(secret.withUnsafeBytes { Data($0) }, key: key, aad: VaultAAD.gated)
        return EnclaveWrap(keyBlob: blob, ephemeralPublicKey: gatedPeer, sealed: sealed)
    }

    static func unwrapGated(_ wrap: EnclaveWrap, enclave: EnclaveProvider, context: LAContext?) throws -> SymmetricKey {
        let key = try gatedWrapKey(blob: wrap.keyBlob, enclave: enclave, context: context)
        return SymmetricKey(data: try open(wrap.sealed, key: key, aad: VaultAAD.gated))
    }

    /// ECIES-style: an ephemeral P-256 key agrees with the enclave key's public half;
    /// HKDF of that shared secret seals the payload. Only the enclave's private half
    /// can recompute it, but anyone can produce one, so this only suits the silent key,
    /// which protects nothing a local process could not already reach.
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

    /// Bounds on the stored work factor. The count comes out of the vault file, which
    /// someone able to write it could set to 0 (a parameter error), a negative number
    /// (a trap converting to `UInt32`), or two billion (the app wedged for hours).
    static let recoveryIterationRange = 100_000...10_000_000

    static func deriveKEK(recoveryKeyBytes: [UInt8], salt: Data, iterations: Int) throws -> SymmetricKey {
        guard recoveryIterationRange.contains(iterations), !salt.isEmpty else { throw VaultError.corrupt }
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
        guard status == kCCSuccess else { throw VaultError.corrupt }
        return SymmetricKey(data: out)
    }

    static func sealRecovery(_ secret: SymmetricKey, recoveryKeyBytes: [UInt8],
                             iterations: Int = recoveryIterations) throws -> RecoveryWrap {
        var salt = [UInt8](repeating: 0, count: 16)
        for i in salt.indices { salt[i] = UInt8.random(in: 0...255) }
        let kek = try deriveKEK(recoveryKeyBytes: recoveryKeyBytes, salt: Data(salt), iterations: iterations)
        let sealed = try seal(secret.withUnsafeBytes { Data($0) }, key: kek, aad: VaultAAD.recovery)
        return RecoveryWrap(salt: Data(salt), iterations: iterations, sealed: sealed)
    }

    static func openRecovery(_ wrap: RecoveryWrap, recoveryKeyBytes: [UInt8]) throws -> SymmetricKey {
        // A damaged work factor is a broken file, not a wrong key — telling the two
        // apart matters, because "wrong recovery key" would send someone hunting for
        // a better copy of a key that was never the problem.
        let kek = try deriveKEK(recoveryKeyBytes: recoveryKeyBytes, salt: wrap.salt, iterations: wrap.iterations)
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
