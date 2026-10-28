import AppKit

enum FileOperations {
    static func trash(_ path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    static func rename(_ path: String, to newName: String) throws -> String {
        let dest = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(newName).path
        try FileManager.default.moveItem(atPath: path, toPath: dest)
        return dest
    }

    /// Copies next to the original as "Name copy.ext", "Name copy 2.ext", … and returns the new name.
    static func duplicate(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        for n in 1...9999 {
            let suffix = n == 1 ? " copy" : " copy \(n)"
            let name = ext.isEmpty ? stem + suffix : stem + suffix + "." + ext
            let dest = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.copyItem(at: url, to: dest)
                return name
            }
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))
    }

    static func copyToPasteboard(_ path: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
    }

    static func pasteboardFileURLs() -> [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Copies each URL into `directory`, appending " copy" when the name is taken. Returns the first new name.
    static func paste(_ urls: [URL], into directory: String) throws -> String? {
        var first: String?
        for url in urls {
            var dest = URL(fileURLWithPath: directory).appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                let ext = url.pathExtension
                let stem = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
                var n = 1
                repeat {
                    let name = stem + (n == 1 ? " copy" : " copy \(n)") + (ext.isEmpty ? "" : "." + ext)
                    dest = URL(fileURLWithPath: directory).appendingPathComponent(name)
                    n += 1
                } while FileManager.default.fileExists(atPath: dest.path)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            if first == nil { first = dest.lastPathComponent }
        }
        return first
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return DirectoryError(code: Int32(underlying.code)).description
        }
        if ns.domain == NSPOSIXErrorDomain { return DirectoryError(code: Int32(ns.code)).description }
        return ns.localizedDescription
    }
}
