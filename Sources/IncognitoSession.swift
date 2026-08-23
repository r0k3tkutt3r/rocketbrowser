import Foundation
import WebKit

/// One incognito browsing session: a window plus every tab and popup spawned from it.
/// Session data (cookies, local storage, caches) lives in a dedicated on-disk WebKit
/// data store identified by a UUID — ~/Library/WebKit/<bundle-id>/WebsiteDataStore/<UUID>.
/// When the last window of the session closes the store is destroyed and its directory
/// deleted. Each "New Incognito Window" starts a fresh session, so separate incognito
/// windows can never see each other's cookies.
final class IncognitoSession {

    let identifier = UUID()
    private(set) var dataStore: WKWebsiteDataStore?
    private var windowCount = 0

    init() {
        dataStore = WKWebsiteDataStore(forIdentifier: identifier)
    }

    func attach() {
        windowCount += 1
    }

    func detach() {
        windowCount -= 1
        if windowCount <= 0 {
            destroy()
        }
    }

    private func destroy() {
        guard let store = dataStore else { return }
        dataStore = nil
        // Wipe the data through the live store first: the network process keeps the
        // session open for as long as the app runs, so remove(forIdentifier:) reports
        // "in use" until next launch — but removeData works on a live store and
        // deletes cookies, storage, and caches from disk immediately.
        let identifier = identifier
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: .distantPast) {
            Self.removeStore(identifier: identifier, attempt: 1)
        }
    }

    /// Tries the real removal API a few times (it succeeds once the network process
    /// lets go), then force-deletes the store's now-empty directory.
    private static func removeStore(identifier: UUID, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(attempt)) {
            WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                if error != nil, attempt < 3 {
                    removeStore(identifier: identifier, attempt: attempt + 1)
                    return
                }
                removeStoreDirectory(identifier: identifier)
            }
        }
    }

    /// Deletes the store's on-disk directory if WebKit hasn't already:
    /// ~/Library/WebKit/<bundle-id>/WebsiteDataStore/<uuid> (lowercased on disk).
    private static func removeStoreDirectory(identifier: UUID) {
        let fileManager = FileManager.default
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let container = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let parent = library.appendingPathComponent("WebKit/\(container)/WebsiteDataStore",
                                                    isDirectory: true)
        let target = identifier.uuidString.lowercased()
        let contents = (try? fileManager.contentsOfDirectory(at: parent,
                                                             includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent.lowercased() == target {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Launch-time sweep: identifier-based stores are used only by incognito sessions,
    /// so any store still on disk was orphaned by a crash, force-quit, or quitting with
    /// incognito windows open. Delete them all — nothing is in use this early, so the
    /// removal API works here; the directory sweep is belt and suspenders.
    static func purgeLeftoverStores() {
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers in
            for identifier in identifiers {
                WKWebsiteDataStore.remove(forIdentifier: identifier) { _ in
                    removeStoreDirectory(identifier: identifier)
                }
            }
        }
    }
}
