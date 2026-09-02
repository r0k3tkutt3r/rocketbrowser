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

        // Rocket put it there, so there is nothing new to record — true whether the
        // entry was saved under this exact host or a sibling one it was offered on.
        if filledByRocket, existing.contains(where: {
            SiteMatcher.matches(entryHost: $0.host, pageHost: host) && $0.username == username
        }) {
            return .ignore
        }

        // Updating is matched on the EXACT host, never merely the same registrable
        // domain. Filling across a domain is a convenience; silently rewriting the
        // stored password of a different host is how one compromised subdomain, or one
        // free account on a shared hosting suffix, would overwrite the real site's
        // entry. A near-miss becomes a second entry, which is visible and reversible.
        guard let known = existing.first(where: {
            SiteMatcher.isExact(entryHost: $0.host, pageHost: host) && $0.username == username
        }) else {
            return .offerSave
        }
        return .offerUpdate(known)
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
