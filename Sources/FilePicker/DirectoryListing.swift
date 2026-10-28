import FSEngine
import Foundation

final class DirectoryListing {
    let path: String
    private let dir: UnsafeMutablePointer<fse_dir>

    private init(path: String, dir: UnsafeMutablePointer<fse_dir>) {
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
