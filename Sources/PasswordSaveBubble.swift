import Cocoa

/// The "Save password for github.com?" popover. Editable username, the password as
/// dots with a reveal toggle, and Save / Never / Not Now.
final class PasswordSaveBubbleController: NSViewController {

    var onSave: ((String) -> Void)?
    var onNever: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let decision: SavePolicy.Decision
    private let credential: PendingCredential
    private let usernameField = NSTextField()
    private let secureField = NSSecureTextField()
    private let plainField = NSTextField()
    private let revealButton = NSButton(image: NSImage(systemSymbolName: "eye", accessibilityDescription: "Reveal")!,
                                        target: nil, action: nil)

    init(decision: SavePolicy.Decision, credential: PendingCredential) {
        self.decision = decision
        self.credential = credential
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 0))
        let isUpdate: Bool
        if case .offerUpdate = decision { isUpdate = true } else { isUpdate = false }

        let title = NSTextField(labelWithString:
            "\(isUpdate ? "Update" : "Save") password for \(SiteMatcher.displayHost(credential.host))?")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        usernameField.stringValue = credential.username
        usernameField.placeholderString = "Username"
        // Read the password out of the vault-grade SecureString only at the moment it needs
        // to be on screen — this field is what the user actually sees when the bubble opens.
        credential.password.withString { secureField.stringValue = $0 }
        secureField.isEditable = false
        plainField.isEditable = false
        plainField.isHidden = true
        revealButton.bezelStyle = .texturedRounded
        revealButton.target = self
        revealButton.action = #selector(toggleReveal)
        let passwordRow = NSStackView(views: [secureField, plainField, revealButton])
        passwordRow.orientation = .horizontal
        passwordRow.spacing = 6

        let save = NSButton(title: isUpdate ? "Update" : "Save", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        let never = NSButton(title: "Never", target: self, action: #selector(neverTapped))
        let notNow = NSButton(title: "Not Now", target: self, action: #selector(notNowTapped))
        let buttons = NSStackView(views: [never, NSView(), notNow, save])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [title, usernameField, passwordRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            usernameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            passwordRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = container
        preferredContentSize = NSSize(width: 340, height: 150)
    }

    @objc private func toggleReveal() {
        let revealing = plainField.isHidden
        // Never keep the plaintext around longer than the reveal is on screen: populate it
        // only when showing, and blank it again the instant it's hidden.
        if revealing { credential.password.withString { plainField.stringValue = $0 } } else { plainField.stringValue = "" }
        plainField.isHidden = !revealing
        secureField.isHidden = revealing
        revealButton.image = NSImage(systemSymbolName: revealing ? "eye.slash" : "eye", accessibilityDescription: nil)
    }

    @objc private func saveTapped() { onSave?(usernameField.stringValue.trimmingCharacters(in: .whitespaces)) }
    @objc private func neverTapped() { onNever?() }
    @objc private func notNowTapped() { onDismiss?() }
}
