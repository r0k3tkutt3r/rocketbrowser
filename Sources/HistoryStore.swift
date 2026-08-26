import Foundation

/// One page view. `dwell` and `viaRedirect` are what let `SuggestionEngine` tell a
/// destination apart from a waypoint (sign-in redirectors, SSO hops, link shorteners)
/// without anyone maintaining a list of such domains.
struct Visit: Codable {
    let id: UUID
    let url: String
    let host: String
    let ts: Date
    /// Seconds the tab stayed on this page. nil while the visit is still open, or for
    /// visits recorded before this field existed.
    var dwell: TimeInterval?
    /// The page was reached by a redirect rather than a click, a typed URL or a bookmark.
    var viaRedirect: Bool

    init(id: UUID = UUID(), url: String, host: String, ts: Date,
         dwell: TimeInterval? = nil, viaRedirect: Bool = false) {
        self.id = id
        self.url = url
        self.host = host
        self.ts = ts
        self.dwell = dwell
        self.viaRedirect = viaRedirect
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, host, ts, dwell, viaRedirect
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
    }
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
        return visit.id
    }

    /// Stamps how long the page was actually on screen.
    func closeVisit(id: UUID, at date: Date = Date()) {
        guard let index = visits.lastIndex(where: { $0.id == id }), visits[index].dwell == nil else { return }
        visits[index].dwell = max(0, date.timeIntervalSince(visits[index].ts))
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

    func clear() {
        visits = []
        pendingSave?.cancel()
        try? FileManager.default.removeItem(at: fileURL)
    }

    func flush() {
        pendingSave?.cancel()
        saveNow()
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
