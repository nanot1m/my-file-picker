import Foundation

enum PinKind: Equatable {
    case recents
    case applications
    case icloud
    case favorite
}

struct Pinned: Equatable {
    let path: String
    let kind: PinKind
    var name: String {
        switch kind {
        case .recents: return "Recents"
        case .applications: return "Applications"
        case .icloud: return "iCloud Drive"
        case .favorite: return (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
        }
    }
    var isVirtual: Bool { kind == .recents || kind == .applications }
}

/// Start-page shortcuts: fixed system entries plus user favorites, shown only in the home folder.
enum Pins {
    static let changed = Notification.Name("FilePicker.pinsChanged")
    static let favoritesKey = "favorites"
    static let showKey = "showPins"
    static let recentsPath = "fp://recents"
    static let applicationsPath = "fp://applications"
    static let iCloudPath = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"

    static func isVirtual(_ path: String) -> Bool { path.hasPrefix("fp://") }

    static var favorites: [String] {
        get { UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: favoritesKey); NotificationCenter.default.post(name: changed, object: nil) }
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

    static func forget(_ path: String) {
        favorites = favorites.filter { $0 != path }
    }

    static func rows(excluding current: String) -> [Pinned] {
        guard current == NSHomeDirectory() else { return [] }
        var rows = [Pinned(path: recentsPath, kind: .recents), Pinned(path: applicationsPath, kind: .applications)]
        if FileManager.default.fileExists(atPath: iCloudPath) { rows.append(Pinned(path: iCloudPath, kind: .icloud)) }
        if enabled { rows += favorites.map { Pinned(path: $0, kind: .favorite) } }
        return rows
    }
}
