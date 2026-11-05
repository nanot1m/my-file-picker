import AppKit
import FSEngine

/// A listing whose entries map to arbitrary paths (Recents, Applications).
struct VirtualListing {
    let listing: DirectoryListing
    let paths: [String]
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
            var paths: [String] = []
            var seen = Set<String>()
            for i in 0..<query.resultCount {
                guard paths.count < limit, let item = query.result(at: i) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                let inHiddenLibrary = path.hasPrefix(home + "/Library/") && !path.hasPrefix(home + "/Library/Mobile Documents/")
                if inHiddenLibrary || path.hasPrefix("/System/") || path.hasPrefix("/private/") || path.hasPrefix("/Library/") || path.contains("/.") { continue }
                if path.hasSuffix(".app") || path.contains(".app/") || path.contains("/node_modules/") || path.contains("/.build/") { continue }
                if seen.insert(path).inserted { paths.append(path) }
            }
            let dir = fse_dir_new()!
            for p in paths { _ = fse_dir_append(dir, (p as NSString).lastPathComponent, 0) }
            completion(VirtualListing(listing: DirectoryListing(path: Pins.recentsPath, dir: dir), paths: paths))
        }
        query.start()
    }
}
