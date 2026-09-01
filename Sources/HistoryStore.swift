import Foundation

/// One page view. `dwell` and `viaRedirect` are what let `SuggestionEngine` tell a
/// destination apart from a waypoint (sign-in redirectors, SSO hops, link shorteners)
/// without anyone maintaining a list of such domains.
struct Visit: Codable, Equatable {
    let id: UUID
    let url: String
    let host: String
    let ts: Date
    /// Seconds the tab stayed on this page. nil while the visit is still open, or for
    /// visits recorded before this field existed.
    var dwell: TimeInterval?
    /// The page was reached by a redirect rather than a click, a typed URL or a bookmark.
    var viaRedirect: Bool
    /// Seconds this tab was actually the front-most window with Rocket active, capped
    /// per visit. This is the engagement signal: a tab left open in the background all
    /// night contributes nothing, and one very long session cannot dominate the model.
    var activeTime: TimeInterval?
    /// The page's own title, for the history window. nil for visits recorded before
    /// titles were stored, and for pages that never reported one.
    var title: String?

    /// A single visit contributes at most this much attention.
    static let activeTimeCap: TimeInterval = 15 * 60

    init(id: UUID = UUID(), url: String, host: String, ts: Date,
         dwell: TimeInterval? = nil, viaRedirect: Bool = false,
         activeTime: TimeInterval? = nil, title: String? = nil) {
        self.id = id
        self.url = url
        self.host = host
        self.ts = ts
        self.dwell = dwell
        self.viaRedirect = viaRedirect
        self.activeTime = activeTime
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, host, ts, dwell, viaRedirect, activeTime, title
    }

    /// History files written before dwell tracking decode with the new fields absent.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try container.decode(String.self, forKey: .url)
        host = try container.decode(String.self, forKey: .host)
        ts = try container.decode(Date.self, forKey: .ts)
        dwell = try container.decodeIfPresent(TimeInterval.self, forKey: .dwell)
        viaRedirect = try container.decodeIfPresent(Bool.self, forKey: .viaRedirect) ?? false
        activeTime = try container.decodeIfPresent(TimeInterval.self, forKey: .activeTime)
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }

    /// What the history window shows as the row's headline: the page's own title when
    /// it reported one, otherwise the host — never an empty row.
    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return host
    }

    /// Attention actually paid to this page. Visits recorded before active-time
    /// tracking fall back to wall-clock dwell so old history still trains something.
    var engagementSeconds: TimeInterval {
        min(activeTime ?? dwell ?? 0, Visit.activeTimeCap)
    }

    /// False for history recorded before attention tracking existed. Unmeasured is not
    /// the same as brief, and scoring it as a bounce would quietly discard old history.
    var hasEngagementData: Bool { activeTime != nil || dwell != nil }
}

extension Notification.Name {
    /// Posted by `HistoryStore` whenever visits are added, retitled or removed, so the
    /// history window can rebuild. Mirrors `.bookmarksDidChange`.
    static let historyDidChange = Notification.Name("RocketHistoryDidChange")
}

/// Local-only visit log used to train new-tab suggestions. Never leaves disk;
/// capped in size, saved with a short debounce to avoid a write per page load.
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var visits: [Visit] = []
    private let fileURL: URL
    private var pendingSave: DispatchWorkItem?
    private let cap = 3000

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let directory = support.appendingPathComponent("Rocket", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("history.json")
        }
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([Visit].self, from: data) {
            visits = decoded
        }
    }

    /// Records a page view and returns its id, which the caller hands back to
    /// `closeVisit` when the tab navigates away or closes.
    @discardableResult
    func record(url: URL, viaRedirect: Bool = false, at date: Date = Date()) -> UUID? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let visit = Visit(url: url.absoluteString, host: host, ts: date, viaRedirect: viaRedirect)
        visits.append(visit)
        if visits.count > cap {
            visits.removeFirst(visits.count - cap)
        }
        scheduleSave()
        notifyChanged()
        return visit.id
    }

    /// Stamps the page's own title once the web view reports one. Titles arrive after
    /// the visit is recorded, and can change again while the page is open, so this is
    /// called from the title observer rather than at record time.
    func setTitle(id: UUID, _ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return }
        guard let index = visits.lastIndex(where: { $0.id == id }), visits[index].title != trimmed else { return }
        visits[index].title = trimmed
        scheduleSave()
        notifyChanged()
    }

    /// Stamps how long the page was on screen, and how much of that was real attention.
    func closeVisit(id: UUID, at date: Date = Date(), activeTime: TimeInterval? = nil) {
        guard let index = visits.lastIndex(where: { $0.id == id }), visits[index].dwell == nil else { return }
        visits[index].dwell = max(0, date.timeIntervalSince(visits[index].ts))
        if let activeTime {
            visits[index].activeTime = min(max(0, activeTime), Visit.activeTimeCap)
        }
        scheduleSave()
    }

    /// Most recent visit per host, newest first — the history half of address bar
    /// suggestions.
    func recentHosts(matching text: String, limit: Int) -> [Visit] {
        let needle = text.lowercased()
        guard !needle.isEmpty else { return [] }
        var seen = Set<String>()
        var results: [Visit] = []
        for visit in visits.reversed() {
            guard visit.host.lowercased().contains(needle)
                    || visit.url.lowercased().contains(needle) else { continue }
            guard seen.insert(visit.host).inserted else { continue }
            results.append(visit)
            if results.count == limit { break }
        }
        return results
    }

    /// Forgets specific visits. Returns the number actually removed so the caller can
    /// skip the retrain when a delete was a no-op.
    @discardableResult
    func remove(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        let before = visits.count
        visits.removeAll { ids.contains($0.id) }
        let removed = before - visits.count
        guard removed > 0 else { return 0 }
        scheduleSave()
        notifyChanged()
        return removed
    }

    func clear() {
        visits = []
        pendingSave?.cancel()
        try? FileManager.default.removeItem(at: fileURL)
        notifyChanged()
    }

    func flush() {
        pendingSave?.cancel()
        saveNow()
    }

    /// Test harnesses construct a store off the main thread, where posting straight
    /// away is fine; the app always mutates from the main thread anyway.
    private func notifyChanged() {
        NotificationCenter.default.post(name: .historyDidChange, object: nil)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func saveNow() {
        if let data = try? JSONEncoder().encode(visits) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
