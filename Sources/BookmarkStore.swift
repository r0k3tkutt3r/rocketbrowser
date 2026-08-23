import Foundation

/// A bookmark, or — when `children` is non-nil — a folder of bookmarks.
struct Bookmark: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var url: String?
    var children: [Bookmark]?

    var isFolder: Bool { children != nil }

    init(id: UUID = UUID(), title: String, url: String? = nil, children: [Bookmark]? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, url, children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Bookmark files from before folders existed have no `id` or `children`.
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        children = try container.decodeIfPresent([Bookmark].self, forKey: .children)
    }
}

extension Notification.Name {
    static let bookmarksDidChange = Notification.Name("RocketBookmarksDidChange")
}

final class BookmarkStore {
    static let shared = BookmarkStore()

    private(set) var items: [Bookmark] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let directory = support.appendingPathComponent("Rocket", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("bookmarks.json")
        }
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            items = decoded
        }
    }

    // MARK: - Queries

    func containsBookmark(url: String) -> Bool {
        Self.flattened(items).contains { $0.url == url }
    }

    private static func flattened(_ list: [Bookmark]) -> [Bookmark] {
        list.flatMap { item -> [Bookmark] in
            if let children = item.children {
                return flattened(children)
            }
            return [item]
        }
    }

    // MARK: - Mutations

    func addBookmark(_ bookmark: Bookmark, toFolderID folderID: UUID? = nil) {
        if let url = bookmark.url, containsBookmark(url: url) { return }
        if let folderID, let index = items.firstIndex(where: { $0.id == folderID && $0.isFolder }) {
            items[index].children?.append(bookmark)
        } else {
            items.append(bookmark)
        }
        save()
    }

    func addFolder(named name: String) {
        items.append(Bookmark(title: name, children: []))
        save()
    }

    func update(id: UUID, title: String, url: String?) {
        items = Self.updating(items) { item in
            guard item.id == id else { return }
            item.title = title
            if !item.isFolder, let url {
                item.url = url
            }
        }
        save()
    }

    /// Moves a bookmark into a folder (or to the top level when `folderID` is nil).
    @discardableResult
    func moveBookmark(id: UUID, intoFolderID folderID: UUID?) -> Bool {
        guard let bookmark = Self.firstItem(withID: id, in: items), !bookmark.isFolder else {
            return false
        }
        if let folderID {
            guard let folder = Self.firstItem(withID: folderID, in: items), folder.isFolder else {
                return false
            }
            if folder.children?.contains(where: { $0.id == id }) == true { return false }
            items = Self.removing(items) { $0.id == id }
            items = Self.updating(items) { item in
                guard item.id == folderID else { return }
                item.children?.append(bookmark)
            }
        } else {
            guard !items.contains(where: { $0.id == id }) else { return false }
            items = Self.removing(items) { $0.id == id }
            items.append(bookmark)
        }
        save()
        return true
    }

    private static func firstItem(withID id: UUID, in list: [Bookmark]) -> Bookmark? {
        for item in list {
            if item.id == id { return item }
            if let children = item.children,
               let found = firstItem(withID: id, in: children) {
                return found
            }
        }
        return nil
    }

    func removeItem(id: UUID) {
        items = Self.removing(items) { $0.id == id }
        save()
    }

    func removeBookmark(url: String) {
        items = Self.removing(items) { $0.url == url }
        save()
    }

    private static func updating(_ list: [Bookmark], _ transform: (inout Bookmark) -> Void) -> [Bookmark] {
        list.map { item in
            var item = item
            transform(&item)
            if let children = item.children {
                item.children = updating(children, transform)
            }
            return item
        }
    }

    private static func removing(_ list: [Bookmark], where predicate: (Bookmark) -> Bool) -> [Bookmark] {
        list.compactMap { item in
            if predicate(item) { return nil }
            var item = item
            if let children = item.children {
                item.children = removing(children, where: predicate)
            }
            return item
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
    }
}
