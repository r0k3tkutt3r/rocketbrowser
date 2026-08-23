import Foundation

struct Visit: Codable {
    let url: String
    let host: String
    let ts: Date
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

    func record(url: URL) {
        guard let host = url.host, !host.isEmpty else { return }
        visits.append(Visit(url: url.absoluteString, host: host, ts: Date()))
        if visits.count > cap {
            visits.removeFirst(visits.count - cap)
        }
        scheduleSave()
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
