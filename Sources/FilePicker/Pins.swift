import Foundation

struct Pinned: Equatable {
    let path: String
    let isFavorite: Bool
    var name: String { (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent }
}

/// Favorites are user-curated; recents are the last folders visited, most recent first.
enum Pins {
    static let changed = Notification.Name("FilePicker.pinsChanged")
    static let favoritesKey = "favorites"
    static let recentsKey = "recents"
    static let showKey = "showPins"
    static let maxRecents = 6
    static let keptRecents = 20

    static var favorites: [String] {
        get { UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: favoritesKey); NotificationCenter.default.post(name: changed, object: nil) }
    }

    static var recents: [String] {
        get { UserDefaults.standard.stringArray(forKey: recentsKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(keptRecents)), forKey: recentsKey); NotificationCenter.default.post(name: changed, object: nil) }
    }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: showKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showKey); NotificationCenter.default.post(name: changed, object: nil) }
    }

    static func isFavorite(_ path: String) -> Bool { favorites.contains(path) }

    static func toggleFavorite(_ path: String) {
        var list = favorites
        if let i = list.firstIndex(of: path) { list.remove(at: i) } else { list.append(path) }
        favorites = list
    }

    static func recordVisit(_ path: String) {
        var list = recents.filter { $0 != path }
        list.insert(path, at: 0)
        recents = list
    }

    static func clearRecents() { recents = [] }

    static func forget(_ path: String) {
        recents = recents.filter { $0 != path }
        favorites = favorites.filter { $0 != path }
    }

    /// Rows to show above a folder's contents: favorites, then recents not already favorited.
    static func rows(excluding current: String) -> [Pinned] {
        guard enabled else { return [] }
        let favs = favorites.filter { $0 != current }
        let recent = recents.filter { $0 != current && !favorites.contains($0) }.prefix(maxRecents)
        return favs.map { Pinned(path: $0, isFavorite: true) } + recent.map { Pinned(path: $0, isFavorite: false) }
    }
}
