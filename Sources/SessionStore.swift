import Foundation

/// One restorable tab.
struct SessionTab: Codable, Equatable {
    let url: String
    let title: String?
}

/// One restorable window, holding its tabs in the order they appeared in the tab bar.
struct SessionWindow: Codable, Equatable {
    let tabs: [SessionTab]
}

/// Everything needed to put the browser back the way it was: the window/tab structure,
/// plus the ⇧⌘T stack so reopening a closed tab survives a restart too.
struct SavedSession: Codable, Equatable {
    let windows: [SessionWindow]
    let closedTabs: [SessionTab]
    let savedAt: Date

    var isEmpty: Bool { windows.isEmpty }

    /// Tabs across every window — what "Reopen Last Session" actually restores.
    var tabCount: Int { windows.reduce(0) { $0 + $1.tabs.count } }
}

/// Turns the live window list into a `SavedSession`.
///
/// Split out from `SessionStore` because snapshotting needs real `NSWindow`s and real
/// controllers, which no test harness can build. Everything that decides *what gets
/// saved* lives here as a pure function over plain values; `AppDelegate` only has to
/// collect the entries.
enum SessionSnapshot {

    /// One live tab, reduced to the facts that decide whether it is saved.
    /// `groupKey` identifies the window's tab group — tabs sharing a key are tabs of
    /// one window, and both the key order and the entry order are preserved.
    struct Entry: Equatable {
        let url: String
        let title: String?
        let groupKey: Int
        let isPrivate: Bool
        /// The internal start page. Restoring it is pointless — a restored window
        /// opens one anyway when it has nothing else to show.
        let isNewTabPage: Bool

        init(url: String, title: String? = nil, groupKey: Int,
             isPrivate: Bool = false, isNewTabPage: Bool = false) {
            self.url = url
            self.title = title
            self.groupKey = groupKey
            self.isPrivate = isPrivate
            self.isNewTabPage = isNewTabPage
        }
    }

    static func build(from entries: [Entry],
                      closedTabs: [SessionTab] = [],
                      at date: Date = Date()) -> SavedSession {
        // Private browsing never reaches disk, and neither does a blank start page.
        let keep = entries.filter { !$0.isPrivate && !$0.isNewTabPage && !$0.url.isEmpty }

        // Group without sorting: first appearance fixes a group's position, and
        // appends within a group preserve tab order. A dictionary would lose both.
        var order: [Int] = []
        var byGroup: [Int: [SessionTab]] = [:]
        for entry in keep {
            if byGroup[entry.groupKey] == nil { order.append(entry.groupKey) }
            byGroup[entry.groupKey, default: []].append(SessionTab(url: entry.url, title: entry.title))
        }

        // A window whose every tab was filtered out is not a window worth restoring.
        let windows = order.compactMap { key -> SessionWindow? in
            guard let tabs = byGroup[key], !tabs.isEmpty else { return nil }
            return SessionWindow(tabs: tabs)
        }
        return SavedSession(windows: windows, closedTabs: closedTabs, savedAt: date)
    }
}

/// Persists the last session to `session.json` in Application Support, next to the
/// other stores. Saving always happens; the `RestoreSession` preference only decides
/// whether launch consumes it automatically.
final class SessionStore {
    static let shared = SessionStore()

    /// Unlike every other setting in Rocket, this defaults to **off**. Restoring tabs
    /// changes what launching the app does, which is something to opt into rather
    /// than discover.
    static var restoresOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: "RestoreSession") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "RestoreSession") }
    }

    /// The ⇧⌘T stack is capped at the same 25 entries `AppDelegate` keeps in memory.
    static let closedTabCap = 25

    private let fileURL: URL
    private var pendingSave: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let directory = support.appendingPathComponent("Rocket", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("session.json")
        }
    }

    /// nil when there is no session file yet, or it cannot be read.
    func load() -> SavedSession? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SavedSession.self, from: data)
    }

    func save(_ session: SavedSession) {
        pendingSave?.cancel()
        pendingSave = nil
        write(session)
    }

    /// Coalesces the per-navigation saves into one write every couple of seconds,
    /// the same way `HistoryStore` avoids a write per page load. The session is
    /// re-snapshotted when the timer fires, not when it is scheduled, so the write
    /// reflects the windows as they are at that moment.
    func scheduleSave(_ snapshot: @escaping () -> SavedSession) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(snapshot()) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Writes any pending save immediately — called from `applicationWillTerminate`,
    /// where there is no later chance to flush.
    func flush(_ snapshot: () -> SavedSession) {
        pendingSave?.cancel()
        pendingSave = nil
        write(snapshot())
    }

    func clear() {
        pendingSave?.cancel()
        pendingSave = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func write(_ session: SavedSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
