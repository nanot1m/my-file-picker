import AppKit
import FSEngine

struct VirtualItem {
    let path: String
    let lastUsed: Date
    let added: Date
    var name: String { (path as NSString).lastPathComponent }
}

/// A listing whose entries map to arbitrary paths (Recents, Applications).
struct VirtualListing {
    let listing: DirectoryListing
    let paths: [String]
    let items: [VirtualItem]

    init(listing: DirectoryListing, paths: [String], items: [VirtualItem] = []) {
        self.listing = listing
        self.paths = paths
        self.items = items
    }

    static func from(items: [VirtualItem], path: String, sort: FolderSort) -> VirtualListing {
        let sorted: [VirtualItem]
        switch sort {
        case .lastOpened: sorted = items.sorted { $0.lastUsed > $1.lastUsed }
        case .dateAdded: sorted = items.sorted { $0.added > $1.added }
        case .name: sorted = items.sorted { fse_name_compare($0.name, $1.name) < 0 }
        }
        let dir = fse_dir_new()!
        for item in sorted { _ = fse_dir_append(dir, item.name, 0) }
        return VirtualListing(listing: DirectoryListing(path: path, dir: dir), paths: sorted.map(\.path), items: sorted)
    }

    func resorted(by sort: FolderSort, path: String) -> VirtualListing {
        items.isEmpty ? self : VirtualListing.from(items: items, path: path, sort: sort)
    }
}

enum VirtualFolders {
    static func applications(completion: @escaping (VirtualListing) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = ApplicationList.scan()
            let paths = (0..<apps.listing.count).map { apps.path(at: $0) }
            DispatchQueue.main.async { completion(VirtualListing(listing: apps.listing, paths: paths)) }
        }
    }

    /// Finder-style Recents: files (not folders) ordered by last-used date, newest first.
    static func recents(limit: Int = 200, completion: @escaping (VirtualListing) -> Void) {
        let query = NSMetadataQuery()
        // NSMetadataQuery rejects "!= nil"; comparing against a distant date selects every item that has a last-used date.
        query.predicate = NSPredicate(format: "%K > %@ AND %K != 'public.folder'",
                                      NSMetadataItemLastUsedDateKey, Date(timeIntervalSince1970: 0) as NSDate, NSMetadataItemContentTypeKey)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.operationQueue = .main
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { _ in
            query.disableUpdates()
            query.stop()
            if let token { NotificationCenter.default.removeObserver(token) }
            let home = NSHomeDirectory()
            var collected: [VirtualItem] = []
            var seen = Set<String>()
            for i in 0..<query.resultCount {
                guard let item = query.result(at: i) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                      let used = item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date else { continue }
                let added = (item.value(forAttribute: "kMDItemDateAdded") as? Date)
                    ?? (item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date) ?? used
                let inHiddenLibrary = path.hasPrefix(home + "/Library/") && !path.hasPrefix(home + "/Library/Mobile Documents/")
                if inHiddenLibrary || path.hasPrefix("/System/") || path.hasPrefix("/private/") || path.hasPrefix("/Library/") || path.contains("/.") { continue }
                if path.hasSuffix(".app") || path.contains(".app/") || path.contains("/node_modules/") || path.contains("/.build/") { continue }
                if seen.insert(path).inserted { collected.append(VirtualItem(path: path, lastUsed: used, added: added)) }
            }
            // Newest first by last-opened date, then cap; the caller may re-sort the capped set.
            let items = Array(collected.sorted { $0.lastUsed > $1.lastUsed }.prefix(limit))
            completion(VirtualListing.from(items: items, path: Pins.recentsPath, sort: FolderSort.forFolder(Pins.recentsPath)))
        }
        query.start()
    }
}
