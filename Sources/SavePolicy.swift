import Foundation

/// Whether a submitted login deserves a bubble. Pure, so every branch is tested.
enum SavePolicy {

    enum Decision: Equatable {
        case ignore
        case offerSave
        case offerUpdate(PasswordEntry)
    }

    /// Rocket cannot compare the typed password with the saved one without unlocking,
    /// so a known account typed by hand is offered as an update; choosing Update
    /// unlocks, and an identical password just bumps `lastUsed`.
    static func decide(host: String, username: String, filledByRocket: Bool,
                       existing: [PasswordEntry], neverSave: Set<String>, isPrivate: Bool) -> Decision {
        if isPrivate { return .ignore }
        if neverSave.contains(host.lowercased()) { return .ignore }
        let known = existing.first {
            SiteMatcher.matches(entryHost: $0.host, pageHost: host) && $0.username == username
        }
        guard let known else { return .offerSave }
        return filledByRocket ? .ignore : .offerUpdate(known)
    }
}

/// 20 characters, every class present by construction, no 0/O/1/l/I look-alikes.
enum PasswordGenerator {
    static let length = 20
    private static let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let lower = Array("abcdefghijkmnopqrstuvwxyz")
    private static let digits = Array("23456789")
    private static let symbols = Array("!@#$%^&*-_+=?")

    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        var characters: [Character] = [
            upper.randomElement(using: &generator)!,
            lower.randomElement(using: &generator)!,
            digits.randomElement(using: &generator)!,
            symbols.randomElement(using: &generator)!,
        ]
        let all = upper + lower + digits + symbols
        while characters.count < length {
            characters.append(all.randomElement(using: &generator)!)
        }
        characters.shuffle(using: &generator)
        return String(characters)
    }
}
