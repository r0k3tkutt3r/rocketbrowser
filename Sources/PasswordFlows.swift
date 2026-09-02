import Cocoa
import UniformTypeIdentifiers

/// The AppKit flows every entry point shares — the Tools menu, the manager window and
/// the save bubble all set up, import, export and restore the same way.
enum PasswordFlows {

    // MARK: Settings

    static var autofillEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "PasswordsAutofill") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "PasswordsAutofill") }
    }

    static var offersToSave: Bool {
        get { UserDefaults.standard.object(forKey: "PasswordsOfferToSave") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "PasswordsOfferToSave") }
    }

    /// 0 = every operation authenticates (the default).
    static var lockAfterSeconds: Int {
        get { UserDefaults.standard.object(forKey: "PasswordsLockAfter") as? Int ?? 0 }
        set {
            UserDefaults.standard.set(newValue, forKey: "PasswordsLockAfter")
            PasswordStore.shared.lockAfter = TimeInterval(newValue)
        }
    }

    static let lockAfterChoices: [(title: String, seconds: Int)] = [
        ("Immediately", 0), ("After 5 Minutes", 300), ("After 15 Minutes", 900), ("After 1 Hour", 3600),
    ]

    /// Plain text on purpose: it must be consulted while the vault is locked, and it
    /// reveals less than history.json already does. Chrome keeps the same list unencrypted.
    static var neverSaveHosts: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "PasswordsNeverSaveHosts") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "PasswordsNeverSaveHosts") }
    }

    static func addNeverSave(host: String) {
        var hosts = neverSaveHosts
        hosts.insert(host.lowercased())
        neverSaveHosts = hosts
    }

    // MARK: Alerts

    /// A sheet when there is a window to hang it on, app-modal otherwise.
    static func run(_ alert: NSAlert, in window: NSWindow?,
                    completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    static func present(_ error: VaultError, in window: NSWindow?) {
        guard !error.isCancellation else { return }
        let alert = NSAlert()
        alert.messageText = "Rocket Passwords"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        run(alert, in: window) { _ in }
    }

    // MARK: Setup

    /// Calls back with true when the vault is ready to use: it already was, or it was
    /// just created and the recovery key acknowledged.
    static func ensureSetUp(from window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let store = PasswordStore.shared
        if store.isSetUp { completion(true); return }
        if store.needsRestore { promptRestore(from: window, completion: completion); return }
        guard store.isEnclaveAvailable else {
            present(.enclaveUnavailable, in: window)
            completion(false)
            return
        }
        let intro = NSAlert()
        intro.messageText = "Set Up Rocket Passwords"
        intro.informativeText = """
        Passwords are encrypted on this Mac and unlocked with Touch ID or your Mac login \
        password. You'll get a recovery key next — the only way to open them on another \
        Mac, or after this one is erased.
        """
        intro.addButton(withTitle: "Continue")
        intro.addButton(withTitle: "Cancel")
        run(intro, in: window) { response in
            guard response == .alertFirstButtonReturn else { completion(false); return }
            store.setUp { result in
                switch result {
                case .failure(let error):
                    present(error, in: window)
                    completion(false)
                case .success(let key):
                    showRecoveryKey(key, title: "Save Your Recovery Key", in: window) { completion(true) }
                }
            }
        }
    }

    static func showRecoveryKey(_ key: String, title: String, in window: NSWindow?,
                                completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = """
        Write this key down and keep it somewhere safe. Rocket cannot show it again. It is \
        the only way to open your passwords on another Mac or after this Mac is erased.
        """
        let accessory = RecoveryKeyAccessoryView(key: key)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Done")
        alert.buttons[0].isEnabled = false
        accessory.onAcknowledge = { [weak alert] acknowledged in
            alert?.buttons[0].isEnabled = acknowledged
        }
        run(alert, in: window) { _ in completion() }
    }

    static func changeRecoveryKey(from window: NSWindow?) {
        PasswordStore.shared.replaceRecoveryKey { result in
            switch result {
            case .failure(let error): present(error, in: window)
            case .success(let key): showRecoveryKey(key, title: "Your New Recovery Key", in: window) {}
            }
        }
    }

    static func promptRestore(from window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Restore Rocket Passwords"
        alert.informativeText = """
        This vault was created on another Mac, or before this one was erased. Enter your \
        recovery key to use it here.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        run(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { completion(false); return }
            PasswordStore.shared.restore(recoveryKey: field.stringValue) { result in
                switch result {
                case .failure(let error):
                    present(error, in: window)
                    completion(false)
                case .success:
                    completion(true)
                }
            }
        }
    }

    // MARK: Import / export

    static func importCSV(from window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Choose a CSV exported from Apple Passwords, Chrome or Firefox."
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            importCSV(at: url, from: window)
        }
        if let window, window.isVisible { panel.beginSheetModal(for: window, completionHandler: handler) }
        else { handler(panel.runModal()) }
    }

    private static func importCSV(at url: URL, from window: NSWindow?) {
        guard let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .utf16)) else {
            present(.io(CocoaError(.fileReadCorruptFile)), in: window)
            return
        }
        guard let parsed = PasswordImport.parse(csv: text) else {
            let alert = NSAlert()
            alert.messageText = "Not a Password CSV"
            alert.informativeText = "The file needs a header row with at least a URL (or name) column and a password column."
            run(alert, in: window) { _ in }
            return
        }
        ensureSetUp(from: window) { ready in
            guard ready else { return }
            PasswordStore.shared.mutate(reason: "import passwords from \(url.lastPathComponent)", { index, secrets -> (Int, Int, Int) in
                let plan = PasswordImport.merge(parsed.credentials, into: index.entries) { secrets[$0]?.password }
                for (entry, credential) in plan.updates {
                    guard let position = index.entries.firstIndex(where: { $0.id == entry.id }) else { continue }
                    index.entries[position].modified = Date()
                    if index.entries[position].url == nil { index.entries[position].url = credential.url }
                    if index.entries[position].title == nil { index.entries[position].title = credential.title }
                    let old = secrets[entry.id]
                    secrets[entry.id] = PasswordSecret(password: credential.password,
                                                       notes: credential.notes ?? old?.notes,
                                                       otpAuth: credential.otpAuth ?? old?.otpAuth)
                }
                for credential in plan.additions {
                    let entry = PasswordEntry(host: credential.host, url: credential.url,
                                              username: credential.username, title: credential.title)
                    index.entries.append(entry)
                    secrets[entry.id] = PasswordSecret(password: credential.password,
                                                       notes: credential.notes, otpAuth: credential.otpAuth)
                }
                return (plan.additions.count, plan.updates.count, plan.skipped)
            }, completion: { result in
                switch result {
                case .failure(let error):
                    present(error, in: window)
                case .success(let (added, updated, skipped)):
                    let alert = NSAlert()
                    alert.messageText = "Import Finished"
                    var parts = ["Imported \(added)", "updated \(updated)", "skipped \(skipped) duplicate\(skipped == 1 ? "" : "s")"]
                    if parsed.unreadableRows > 0 { parts.append("\(parsed.unreadableRows) row\(parsed.unreadableRows == 1 ? "" : "s") unreadable") }
                    alert.informativeText = parts.joined(separator: ", ") + ".\n\nThe CSV still holds every password in plain text. Move it to the Trash? (The Trash is not a secure erase — empty it, and remember other copies may exist.)"
                    alert.addButton(withTitle: "Move to Trash")
                    alert.addButton(withTitle: "Keep File")
                    run(alert, in: window) { response in
                        guard response == .alertFirstButtonReturn else { return }
                        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                }
            })
        }
    }

    static func exportCSV(from window: NSWindow?) {
        let store = PasswordStore.shared
        guard store.isSetUp else { present(.notSetUp, in: window); return }
        let warning = NSAlert()
        warning.messageText = "Export Passwords?"
        warning.informativeText = "The file will contain every password in plain text. Anyone who can read the file can read them."
        warning.alertStyle = .warning
        warning.addButton(withTitle: "Export…")
        warning.addButton(withTitle: "Cancel")
        run(warning, in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "Rocket Passwords.csv"
            let handler: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                store.withSecrets(reason: "export your passwords", { secrets in
                    PasswordExport.csv(entries: store.entries, secrets: secrets)
                }, completion: { result in
                    switch result {
                    case .failure(let error): present(error, in: window)
                    case .success(let csv):
                        do {
                            try csv.data(using: .utf8)!.write(to: url, options: .atomic)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                        } catch { present(.io(error), in: window) }
                    }
                })
            }
            if let window, window.isVisible { panel.beginSheetModal(for: window, completionHandler: handler) }
            else { handler(panel.runModal()) }
        }
    }
}

/// The recovery key, a Copy button, and the acknowledgement checkbox that unlocks Done.
final class RecoveryKeyAccessoryView: NSView {

    var onAcknowledge: ((Bool) -> Void)?
    private let key: String
    private let checkbox: NSButton

    init(key: String) {
        self.key = key
        checkbox = NSButton(checkboxWithTitle: "I've saved this key somewhere safe", target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 84))

        let field = NSTextField(labelWithString: key)
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        field.alignment = .center
        field.frame = NSRect(x: 0, y: 52, width: 318, height: 24)
        addSubview(field)

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyKey))
        copy.frame = NSRect(x: 322, y: 48, width: 78, height: 30)
        addSubview(copy)

        checkbox.target = self
        checkbox.action = #selector(toggled)
        checkbox.frame = NSRect(x: 0, y: 8, width: 400, height: 20)
        addSubview(checkbox)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func copyKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
    }

    @objc private func toggled() {
        onAcknowledge?(checkbox.state == .on)
    }
}
