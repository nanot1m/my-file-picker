import FSEngine
import Foundation

final class DirectoryListing {
    let path: String
    private let dir: UnsafeMutablePointer<fse_dir>

    init(path: String, dir: UnsafeMutablePointer<fse_dir>) {
        self.path = path
        self.dir = dir
    }

    deinit { fse_dir_free(dir) }

    static func read(path: String, includeHidden: Bool) -> Result<DirectoryListing, DirectoryError> {
        var opts = fse_options(include_hidden: includeHidden ? 1 : 0)
        var err: Int32 = 0
        guard let dir = fse_dir_read(path, &opts, &err) else {
            return .failure(DirectoryError(code: err))
        }
        return .success(DirectoryListing(path: path, dir: dir))
    }

    var count: Int { Int(dir.pointee.count) }
    var directoryCount: Int { Int(dir.pointee.dir_count) }
    var readMilliseconds: Double { Double(dir.pointee.read_ns) / 1_000_000 }
    var sortMilliseconds: Double { Double(dir.pointee.sort_ns) / 1_000_000 }
    var memoryBytes: Int { fse_dir_memory(dir) }

    func name(at index: Int) -> String {
        String(cString: fse_entry_name(dir, UInt32(index)))
    }

    func isDirectory(at index: Int) -> Bool { flags(at: index) & UInt16(FSE_DIR) != 0 }
    func isSymlink(at index: Int) -> Bool { flags(at: index) & UInt16(FSE_SYMLINK) != 0 }

    func fullPath(at index: Int) -> String {
        path == "/" ? "/" + name(at: index) : path + "/" + name(at: index)
    }

    func index(ofName target: String) -> Int? {
        for i in 0..<count where target.withCString({ strcmp($0, fse_entry_name(dir, UInt32(i))) == 0 }) {
            return i
        }
        return nil
    }

    /// Safe to call off the main thread; the listing is immutable once read.
    func filter(query: String) -> (indices: [UInt32], exactMatch: Bool) {
        guard count > 0 else { return ([], false) }
        var out = [fse_match](repeating: fse_match(), count: count)
        let n = Int(fse_filter(dir, query, &out))
        var indices = [UInt32](repeating: 0, count: n)
        var exact = false
        for i in 0..<n {
            indices[i] = out[i].index
            if !exact, out[i].score >= 0, query.withCString({ strcmp($0, fse_entry_name(dir, out[i].index)) == 0 }) { exact = true }
        }
        return (indices, exact)
    }

    private func flags(at index: Int) -> UInt16 { dir.pointee.entries[index].flags }
}

struct DirectoryError: Error, CustomStringConvertible {
    let code: Int32
    var description: String {
        switch code {
        case EACCES, EPERM: return "Permission denied"
        case ENOENT: return "No such directory"
        case ENOTDIR: return "Not a directory"
        default: return String(cString: strerror(code))
        }
    }
}

final class DirectoryLoader {
    private let queue = DispatchQueue(label: "com.hazam.filepicker.fs", qos: .userInteractive)
    private var generation: UInt64 = 0

    /// Must be called on the main thread. Results for superseded requests are dropped.
    @discardableResult
    func load(_ path: String, includeHidden: Bool,
              completion: @escaping (Result<DirectoryListing, DirectoryError>) -> Void) -> UInt64 {
        generation += 1
        let gen = generation
        queue.async {
            let result = DirectoryListing.read(path: path, includeHidden: includeHidden)
            DispatchQueue.main.async { [self] in
                guard gen == generation else { return }
                completion(result)
            }
        }
        return gen
    }
}

extension DirectoryListing {
    /// Builds a listing from arbitrary titles, in the given order, so it can be fuzzy-filtered.
    static func synthetic(_ titles: [String]) -> DirectoryListing {
        let dir = fse_dir_new()!
        for title in titles { _ = fse_dir_append(dir, title, 0) }
        return DirectoryListing(path: "", dir: dir)
    }
}

struct ApplicationList {
    static let searchRoots = [
        "/Applications", "/Applications/Utilities",
        "/System/Applications", "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    let listing: DirectoryListing
    private let paths: [String]

    func path(at index: Int) -> String { paths[index] }

    /// Blocking; run off the main thread.
    static func scan() -> ApplicationList {
        var named: [(name: String, path: String)] = []
        var opts = fse_options(include_hidden: 0)
        for root in searchRoots {
            var err: Int32 = 0
            guard let d = fse_dir_read(root, &opts, &err) else { continue }
            defer { fse_dir_free(d) }
            for i in 0..<Int(d.pointee.count) where d.pointee.entries[i].flags & UInt16(FSE_DIR | FSE_SYMLINK) != 0 {
                let name = String(cString: fse_entry_name(d, UInt32(i)))
                guard name.hasSuffix(".app") else { continue }
                named.append((String(name.dropLast(4)), root + "/" + name))
            }
        }
        named.sort { fse_name_compare($0.name, $1.name) < 0 }
        return ApplicationList(listing: .synthetic(named.map(\.name)), paths: named.map(\.path))
    }
}
