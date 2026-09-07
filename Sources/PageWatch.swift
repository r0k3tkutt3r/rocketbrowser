import Foundation

/// A value on a page that Rocket rechecks on its own — a price, a stock line, a queue
/// position — and reports when it moves.
///
/// The element is pinned by a CSS path built at the moment you select it, and that path
/// is verified to select exactly the node you highlighted before the watch is accepted.
/// A path that later stops matching is recorded as missing rather than deleted: a page
/// mid-deploy is the common case, a page gone forever is not.
struct PageWatch: Codable, Equatable {
    let id: UUID
    var url: String
    var host: String
    var title: String
    var selector: String
    /// The element's whole text, not the fragment that happened to be selected — that is
    /// what every later check reads, so it is what the first one has to record.
    var value: String
    var previousValue: String?
    var interval: TimeInterval
    var checkedAt: Date?
    var changedAt: Date?
    var missingSince: Date?
    /// Changed since the user last opened the list.
    var unread: Bool
    /// The comparison this value belongs to, if any — nothing but a shared name. Being
    /// optional is what migrates every watch written before comparisons existed: the
    /// synthesized decoder reads a missing key as nil.
    var comparison: String?

    init(id: UUID = UUID(), url: String, host: String, title: String, selector: String,
         value: String, previousValue: String? = nil, interval: TimeInterval,
         checkedAt: Date? = nil, changedAt: Date? = nil, missingSince: Date? = nil,
         unread: Bool = false, comparison: String? = nil) {
        self.id = id
        self.url = url
        self.host = host
        self.title = title
        self.selector = selector
        self.value = value
        self.previousValue = previousValue
        self.interval = interval
        self.checkedAt = checkedAt
        self.changedAt = changedAt
        self.missingSince = missingSince
        self.unread = unread
        self.comparison = comparison
    }

    /// How often a watch may be rechecked. Nothing shorter than an hour: these are
    /// prices and stock lines, and a browser that reloads someone's cart page every
    /// minute is a scraper.
    static let intervals: [(title: String, seconds: TimeInterval)] = [
        ("Every hour", 3600),
        ("Every 6 hours", 6 * 3600),
        ("Every day", 24 * 3600),
    ]
    static let defaultInterval: TimeInterval = 6 * 3600

    /// What a launch is worth telling someone about: changes they have not seen in the
    /// Watches menu (`unread`) that are also newer than the last thing announced. The
    /// second half is what stops quitting and reopening three times from delivering the
    /// same news three times, newest first.
    static func unannounced(in watches: [PageWatch], since announced: Date) -> [PageWatch] {
        watches
            .filter { $0.unread && ($0.changedAt ?? .distantPast) > announced }
            .sorted { ($0.changedAt ?? .distantPast) > ($1.changedAt ?? .distantPast) }
    }
}

/// Reading a watched value as a number when it is one, and as text when it is not.
enum WatchValue {

    enum Change: Equatable {
        case unchanged
        case increased(by: Double)
        case decreased(by: Double)
        /// Moved, but not in a way that subtracts — "In stock" to "Sold out".
        case changed
    }

    /// The first number in a string, currency symbols, thousands separators and all.
    ///
    /// ponytail: a lone separator with three digits behind it is read as grouping, so
    /// "12.345" is twelve thousand rather than twelve point three four five. That is the
    /// right guess for prices and the wrong one for rates; a per-watch format would be
    /// the upgrade if anyone ever watches a rate.
    static func number(from text: String) -> Double? {
        guard let start = text.firstIndex(where: { $0.isASCII && $0.isNumber }) else { return nil }
        var digits = ""
        for character in text[start...] {
            guard (character.isASCII && character.isNumber) || character == "." || character == "," else { break }
            digits.append(character)
        }
        while let last = digits.last, last == "." || last == "," { digits.removeLast() }
        guard !digits.isEmpty else { return nil }

        let dots = digits.filter { $0 == "." }.count
        let commas = digits.filter { $0 == "," }.count
        if dots > 0 && commas > 0 {
            // Both present: whichever comes last is the decimal point, and the other one
            // groups thousands. "1,299.00" and "1.299,00" are the same money.
            let decimal: Character = digits.lastIndex(of: ".")! > digits.lastIndex(of: ",")! ? "." : ","
            let normalized = digits.compactMap { character -> Character? in
                if character == decimal { return "." }
                return (character == "." || character == ",") ? nil : character
            }
            return Double(String(normalized))
        }
        if dots + commas > 0 {
            let separator: Character = dots > 0 ? "." : ","
            let groups = digits.split(separator: separator, omittingEmptySubsequences: false)
            let grouping = groups.count > 2 || (groups.count == 2 && groups[1].count == 3)
            return Double(digits.replacingOccurrences(of: String(separator),
                                                      with: grouping ? "" : "."))
        }
        return Double(digits)
    }

    static func compare(old: String, new: String) -> Change {
        let oldText = collapseWhitespace(old)
        let newText = collapseWhitespace(new)
        if let oldNumber = number(from: oldText), let newNumber = number(from: newText) {
            // Equal numbers in different clothes ("$30" becoming "30.00 USD") are not news.
            if oldNumber == newNumber { return .unchanged }
            return newNumber > oldNumber
                ? .increased(by: newNumber - oldNumber)
                : .decreased(by: oldNumber - newNumber)
        }
        return oldText == newText ? .unchanged : .changed
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The arrow a menu row leads with. Nil when nothing moved.
    static func marker(for change: Change) -> String? {
        switch change {
        case .unchanged: return nil
        case .increased: return "▲"
        case .decreased: return "▼"
        case .changed: return "•"
        }
    }
}

extension Notification.Name {
    /// Posted whenever a watch is added, rechecked or removed, so the menu and the Dock
    /// badge can follow. Mirrors `.bookmarksDidChange`.
    static let watchesDidChange = Notification.Name("RocketWatchesDidChange")
}

/// Local-only list of watched values, saved as JSON beside the other stores.
final class PageWatchStore {
    static let shared = PageWatchStore()

    private(set) var watches: [PageWatch] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let directory = support.appendingPathComponent("Rocket", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("watches.json")
        }
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([PageWatch].self, from: data) {
            watches = decoded
        }
    }

    var unreadCount: Int { watches.filter(\.unread).count }

    func watch(id: UUID) -> PageWatch? { watches.first { $0.id == id } }

    /// Watches that have never been checked, or whose interval has elapsed.
    func due(at date: Date = Date()) -> [PageWatch] {
        watches.filter { watch in
            guard let checked = watch.checkedAt else { return true }
            return date.timeIntervalSince(checked) >= watch.interval
        }
    }

    func add(_ watch: PageWatch) {
        watches.append(watch)
        save()
    }

    func remove(id: UUID) {
        watches.removeAll { $0.id == id }
        save()
    }

    func update(id: UUID, _ body: (inout PageWatch) -> Void) {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { return }
        body(&watches[index])
        save()
    }

    func markAllRead() {
        guard watches.contains(where: \.unread) else { return }
        for index in watches.indices { watches[index].unread = false }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(watches) {
            try? data.write(to: fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: .watchesDidChange, object: nil)
    }
}
