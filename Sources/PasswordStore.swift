import Foundation
import CryptoKit
import LocalAuthentication

extension Notification.Name {
    static let passwordsDidChange = Notification.Name("rocket.passwordsDidChange")
}

// MARK: - Authentication

/// Hands back an `LAContext` that has just passed device-owner authentication (Touch
/// ID, with the macOS password as the system's own fallback). Always completes on the
/// main thread. Harnesses substitute a stub that returns a bare `LAContext()`.
protocol Authenticator {
    func authenticate(reason: String, completion: @escaping (Result<LAContext?, VaultError>) -> Void)
}

final class LocalAuthenticator: Authenticator {
    func authenticate(reason: String, completion: @escaping (Result<LAContext?, VaultError>) -> Void) {
        let context = LAContext()
        // Every operation is its own decision: no reuse of a recent Touch ID.
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(.failure(.authenticationFailed(error)))
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, evaluationError in
            DispatchQueue.main.async {
                if ok {
                    completion(.success(context))
                } else if let la = evaluationError as? LAError,
                          [.userCancel, .appCancel, .systemCancel].contains(la.code) {
                    completion(.failure(.cancelled))
                } else {
                    completion(.failure(.authenticationFailed(evaluationError)))
                }
            }
        }
    }
}

// MARK: - Store

/// Owns the vault. The index (sites and usernames) is decrypted once, silently, and
/// kept; secrets exist only inside `mutate`/`withSecrets`, behind one authentication
/// per operation unless `lockAfter` says the key may be kept for a while.
final class PasswordStore {

    static let shared = PasswordStore()

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rocket", isDirectory: true)
            .appendingPathComponent("passwords.vault")
    }

    static var storedLockAfter: TimeInterval {
        TimeInterval(UserDefaults.standard.object(forKey: "PasswordsLockAfter") as? Int ?? 0)
    }

    let fileURL: URL
    private let enclave: EnclaveProvider
    private let authenticator: Authenticator

    /// Seconds an unlocked vault key stays cached; 0 means every operation authenticates.
    var lockAfter: TimeInterval {
        didSet { if lockAfter <= 0 { lockNow() } }
    }
    /// PBKDF2 work factor for the recovery wrap. Harnesses lower it.
    var recoveryIterations = VaultCrypto.recoveryIterations

    private var file: VaultFile?
    private var indexKey: SymmetricKey?
    private(set) var entries: [PasswordEntry] = []
    /// passwords.vault exists but this Mac's enclave cannot open its silent key: the
    /// one check that needs no prompt, and a blob from another enclave always fails it.
    private(set) var needsRestore = false
    private var loaded = false

    private var cachedKey: SecureBytes?
    private var lockTimer: Timer?

    init(fileURL: URL = PasswordStore.defaultFileURL,
         enclave: EnclaveProvider = SecureEnclaveProvider(),
         authenticator: Authenticator = LocalAuthenticator(),
         lockAfter: TimeInterval = PasswordStore.storedLockAfter) {
        self.fileURL = fileURL
        self.enclave = enclave
        self.authenticator = authenticator
        self.lockAfter = lockAfter
    }

    // MARK: State

    var isEnclaveAvailable: Bool { enclave.isAvailable }
    var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
    var isSetUp: Bool { load(); return file != nil && !needsRestore }
    var isUnlocked: Bool { cachedKey != nil }

    var entriesLoaded: [PasswordEntry] { load(); return entries }

    func entries(for host: String) -> [PasswordEntry] {
        load()
        return SiteMatcher.rank(entries: entries, forPageHost: host)
    }

    func entry(id: UUID) -> PasswordEntry? {
        load()
        return entries.first { $0.id == id }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? VaultCrypto.decode(VaultFile.self, from: data) else { return }
        file = decoded
        do {
            let key = try VaultCrypto.unwrap(decoded.silent, enclave: enclave, context: nil, aad: VaultAAD.silent)
            let indexData = try VaultCrypto.open(decoded.index, key: key, aad: VaultAAD.index)
            entries = try VaultCrypto.decode(VaultIndex.self, from: indexData).entries
            indexKey = key
        } catch {
            needsRestore = true
        }
    }

    // MARK: Setup

    /// Creates the vault and returns the recovery key, which is shown exactly once.
    /// The gated wrap is opened (one Touch ID) before anything is written: a vault
    /// that could never be unlocked must not be saved.
    func setUp(completion: @escaping (Result<String, VaultError>) -> Void) {
        load()
        guard enclave.isAvailable else { completion(.failure(.enclaveUnavailable)); return }
        let vaultKey = SymmetricKey(size: .bits256)
        let newIndexKey = SymmetricKey(size: .bits256)
        let recoveryKey = RecoveryKey.generate()
        let draft: VaultFile
        do {
            draft = try makeFile(vaultKey: vaultKey, indexKey: newIndexKey,
                                 recoveryKeyBytes: RecoveryKey.normalize(recoveryKey)!,
                                 index: VaultIndex(), secrets: VaultSecrets())
        } catch {
            completion(.failure(Self.wrap(error)))
            return
        }
        authenticator.authenticate(reason: "set up Rocket Passwords") { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let context):
                do {
                    let opened = try VaultCrypto.unwrap(draft.gated, enclave: self.enclave,
                                                        context: context, aad: VaultAAD.gated)
                    guard opened == vaultKey else { throw VaultError.corrupt }
                    try self.write(draft)
                    self.file = draft
                    self.indexKey = newIndexKey
                    self.entries = []
                    self.needsRestore = false
                    self.cache(vaultKey)
                    NotificationCenter.default.post(name: .passwordsDidChange, object: self)
                    completion(.success(recoveryKey))
                } catch {
                    completion(.failure(Self.wrap(error)))
                }
            }
        }
    }

    private func makeFile(vaultKey: SymmetricKey, indexKey: SymmetricKey, recoveryKeyBytes: [UInt8],
                          index: VaultIndex, secrets: VaultSecrets) throws -> VaultFile {
        let gatedBlob = try enclave.makeKey(gated: true)
        let silentBlob = try enclave.makeKey(gated: false)
        return VaultFile(
            version: VaultFile.currentVersion,
            gated: try VaultCrypto.wrap(vaultKey, blob: gatedBlob, enclave: enclave, aad: VaultAAD.gated),
            silent: try VaultCrypto.wrap(indexKey, blob: silentBlob, enclave: enclave, aad: VaultAAD.silent),
            recovery: try VaultCrypto.sealRecovery(vaultKey, recoveryKeyBytes: recoveryKeyBytes,
                                                   iterations: recoveryIterations),
            indexKeyUnderVaultKey: try VaultCrypto.seal(indexKey.withUnsafeBytes { Data($0) },
                                                        key: vaultKey, aad: VaultAAD.indexKey),
            index: try VaultCrypto.seal(try VaultCrypto.encode(index), key: indexKey, aad: VaultAAD.index),
            secrets: try VaultCrypto.seal(try VaultCrypto.encode(secrets), key: vaultKey, aad: VaultAAD.secrets),
            modified: Date())
    }

    // MARK: Unlocking

    private func obtainVaultKey(reason: String, completion: @escaping (Result<SymmetricKey, VaultError>) -> Void) {
        load()
        guard let file, !needsRestore else {
            completion(.failure(needsRestore ? .enclaveKeyUnusable : .notSetUp))
            return
        }
        if let cachedKey {
            touchLockTimer()
            completion(.success(cachedKey.symmetricKey))
            return
        }
        authenticator.authenticate(reason: reason) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let context):
                do {
                    let key = try VaultCrypto.unwrap(file.gated, enclave: self.enclave,
                                                     context: context, aad: VaultAAD.gated)
                    self.cache(key)
                    completion(.success(key))
                } catch {
                    completion(.failure(Self.wrap(error)))
                }
            }
        }
    }

    private func cache(_ key: SymmetricKey) {
        guard lockAfter > 0 else { return }
        cachedKey?.wipe()
        cachedKey = SecureBytes(key)
        touchLockTimer()
    }

    private func touchLockTimer() {
        lockTimer?.invalidate()
        lockTimer = nil
        guard lockAfter > 0 else { return }
        lockTimer = Timer.scheduledTimer(withTimeInterval: lockAfter, repeats: false) { [weak self] _ in
            self?.lockNow()
        }
    }

    func lockNow() {
        lockTimer?.invalidate()
        lockTimer = nil
        cachedKey?.wipe()
        cachedKey = nil
    }

    // MARK: Secrets

    /// The only path to K. Runs `body` with the decrypted secrets and a working copy of
    /// the index; whatever it changes is re-sealed and saved before `completion`.
    func mutate<T>(reason: String,
                   _ body: @escaping (inout VaultIndex, inout VaultSecrets) throws -> T,
                   completion: @escaping (Result<T, VaultError>) -> Void) {
        obtainVaultKey(reason: reason) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let key):
                do {
                    guard var file = self.file, let indexKey = self.indexKey else { throw VaultError.notSetUp }
                    var secretsData = try VaultCrypto.open(file.secrets, key: key, aad: VaultAAD.secrets)
                    defer { secretsData.resetBytes(in: 0..<secretsData.count) }
                    var secrets = try VaultCrypto.decode(VaultSecrets.self, from: secretsData)
                    var index = VaultIndex(entries: self.entries)
                    let value = try body(&index, &secrets)
                    var newSecrets = try VaultCrypto.encode(secrets)
                    defer { newSecrets.resetBytes(in: 0..<newSecrets.count) }
                    let newIndex = try VaultCrypto.encode(index)
                    let oldIndex = try VaultCrypto.encode(VaultIndex(entries: self.entries))
                    if newSecrets != secretsData || newIndex != oldIndex {
                        file.secrets = try VaultCrypto.seal(newSecrets, key: key, aad: VaultAAD.secrets)
                        file.index = try VaultCrypto.seal(newIndex, key: indexKey, aad: VaultAAD.index)
                        file.modified = Date()
                        try self.write(file)
                        self.file = file
                        self.entries = index.entries
                        NotificationCenter.default.post(name: .passwordsDidChange, object: self)
                    }
                    completion(.success(value))
                } catch {
                    completion(.failure(Self.wrap(error)))
                }
            }
        }
    }

    func withSecrets<T>(reason: String,
                        _ body: @escaping (VaultSecrets) throws -> T,
                        completion: @escaping (Result<T, VaultError>) -> Void) {
        mutate(reason: reason, { _, secrets in try body(secrets) }, completion: completion)
    }

    func password(for id: UUID, reason: String,
                  completion: @escaping (Result<SecureString, VaultError>) -> Void) {
        withSecrets(reason: reason, { secrets in
            guard let secret = secrets[id] else { throw VaultError.corrupt }
            return SecureString(secret.password)
        }, completion: completion)
    }

    func add(_ entry: PasswordEntry, secret: PasswordSecret, reason: String,
             completion: @escaping (Result<Void, VaultError>) -> Void) {
        mutate(reason: reason, { index, secrets in
            index.entries.append(entry)
            secrets[entry.id] = secret
        }, completion: completion)
    }

    /// Replaces the index entry; the secret too when one is given.
    func update(_ entry: PasswordEntry, secret: PasswordSecret?, reason: String,
                completion: @escaping (Result<Void, VaultError>) -> Void) {
        mutate(reason: reason, { index, secrets in
            guard let position = index.entries.firstIndex(where: { $0.id == entry.id }) else {
                throw VaultError.corrupt
            }
            var updated = entry
            updated.modified = Date()
            index.entries[position] = updated
            if let secret { secrets[entry.id] = secret }
        }, completion: completion)
    }

    func delete(ids: Set<UUID>, reason: String, completion: @escaping (Result<Void, VaultError>) -> Void) {
        mutate(reason: reason, { index, secrets in
            index.entries.removeAll { ids.contains($0.id) }
            for id in ids { secrets[id] = nil }
        }, completion: completion)
    }

    /// Index-only, so it never prompts: the index key is this Mac's to use.
    func markUsed(id: UUID) {
        load()
        guard let position = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[position].lastUsed = Date()
        try? resealIndex()
        NotificationCenter.default.post(name: .passwordsDidChange, object: self)
    }

    private func resealIndex() throws {
        guard var file, let indexKey else { throw VaultError.notSetUp }
        file.index = try VaultCrypto.seal(try VaultCrypto.encode(VaultIndex(entries: entries)),
                                          key: indexKey, aad: VaultAAD.index)
        file.modified = Date()
        try write(file)
        self.file = file
    }

    // MARK: Recovery

    func replaceRecoveryKey(completion: @escaping (Result<String, VaultError>) -> Void) {
        obtainVaultKey(reason: "change your Rocket Passwords recovery key") { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let key):
                do {
                    guard var file = self.file else { throw VaultError.notSetUp }
                    let recoveryKey = RecoveryKey.generate()
                    file.recovery = try VaultCrypto.sealRecovery(key, recoveryKeyBytes: RecoveryKey.normalize(recoveryKey)!,
                                                                 iterations: self.recoveryIterations)
                    file.modified = Date()
                    try self.write(file)
                    self.file = file
                    completion(.success(recoveryKey))
                } catch {
                    completion(.failure(Self.wrap(error)))
                }
            }
        }
    }

    /// Rebinds a vault to this Mac's enclave: opens K with the recovery key, Ki with K,
    /// creates fresh enclave keys, and rewrites every wrap. The recovery key itself is
    /// kept, so the same paper still works afterwards.
    func restore(recoveryKey: String, completion: @escaping (Result<Void, VaultError>) -> Void) {
        guard enclave.isAvailable else { completion(.failure(.enclaveUnavailable)); return }
        guard let data = try? Data(contentsOf: fileURL),
              let existing = try? VaultCrypto.decode(VaultFile.self, from: data) else {
            completion(.failure(.corrupt))
            return
        }
        guard let bytes = RecoveryKey.normalize(recoveryKey) else { completion(.failure(.wrongRecoveryKey)); return }
        let vaultKey: SymmetricKey
        let restoredIndexKey: SymmetricKey
        let index: VaultIndex
        let secrets: VaultSecrets
        do {
            vaultKey = try VaultCrypto.openRecovery(existing.recovery, recoveryKeyBytes: bytes)
            restoredIndexKey = SymmetricKey(data: try VaultCrypto.open(existing.indexKeyUnderVaultKey,
                                                                        key: vaultKey, aad: VaultAAD.indexKey))
            index = try VaultCrypto.decode(VaultIndex.self,
                                           from: try VaultCrypto.open(existing.index, key: restoredIndexKey, aad: VaultAAD.index))
            secrets = try VaultCrypto.decode(VaultSecrets.self,
                                             from: try VaultCrypto.open(existing.secrets, key: vaultKey, aad: VaultAAD.secrets))
        } catch {
            completion(.failure(Self.wrap(error)))
            return
        }
        let draft: VaultFile
        do {
            var rebuilt = try makeFile(vaultKey: vaultKey, indexKey: restoredIndexKey, recoveryKeyBytes: bytes,
                                       index: index, secrets: secrets)
            rebuilt.recovery = existing.recovery
            draft = rebuilt
        } catch {
            completion(.failure(Self.wrap(error)))
            return
        }
        authenticator.authenticate(reason: "restore Rocket Passwords on this Mac") { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let context):
                do {
                    let opened = try VaultCrypto.unwrap(draft.gated, enclave: self.enclave,
                                                        context: context, aad: VaultAAD.gated)
                    guard opened == vaultKey else { throw VaultError.corrupt }
                    try self.write(draft)
                    self.file = draft
                    self.indexKey = restoredIndexKey
                    self.entries = index.entries
                    self.needsRestore = false
                    self.loaded = true
                    NotificationCenter.default.post(name: .passwordsDidChange, object: self)
                    completion(.success(()))
                } catch {
                    completion(.failure(Self.wrap(error)))
                }
            }
        }
    }

    // MARK: Disk

    private func write(_ file: VaultFile) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw VaultError.io(error)
        }
    }

    private static func wrap(_ error: Error) -> VaultError {
        (error as? VaultError) ?? .io(error)
    }
}
