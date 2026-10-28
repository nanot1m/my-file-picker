import FSEngine
import Foundation
import Testing

private struct TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("fse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
    func touch(_ name: String, bytes: Int = 0) throws { try Data(count: bytes).write(to: url.appendingPathComponent(name)) }
    func mkdir(_ name: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(name), withIntermediateDirectories: false)
    }
    func link(_ name: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent(name),
                                                   withDestinationURL: url.appendingPathComponent(target))
    }
    func read(hidden: Bool = false) throws -> UnsafeMutablePointer<fse_dir> {
        var opts = fse_options(include_hidden: hidden ? 1 : 0)
        var err: Int32 = 0
        guard let d = fse_dir_read(url.path, &opts, &err) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(err)) }
        return d
    }
}

private func names(_ d: UnsafeMutablePointer<fse_dir>) -> [String] {
    (0..<Int(d.pointee.count)).map { String(cString: fse_entry_name(d, UInt32($0))) }
}

@Test func directoriesFirstThenNaturalOrder() throws {
    let t = try TempDir(); defer { t.cleanup() }
    try t.touch("b.txt", bytes: 10)
    try t.touch("a.txt")
    try t.touch("file10")
    try t.touch("file2")
    try t.mkdir("Zeta")
    try t.mkdir("alpha")
    let d = try t.read(); defer { fse_dir_free(d) }
    #expect(names(d) == ["alpha", "Zeta", "a.txt", "b.txt", "file2", "file10"])
    #expect(d.pointee.dir_count == 2)
    #expect(d.pointee.entries[0].flags & UInt16(FSE_DIR) != 0)
    #expect(d.pointee.entries[3].size == 10)
    #expect(d.pointee.entries[3].name_len == 5)
}

@Test func hiddenFilteringAndSymlinks() throws {
    let t = try TempDir(); defer { t.cleanup() }
    try t.touch(".hidden")
    try t.touch("visible")
    try t.link("link", to: "visible")
    try t.link("dangling", to: "missing")
    let d = try t.read(); defer { fse_dir_free(d) }
    #expect(names(d) == ["dangling", "link", "visible"])
    #expect(d.pointee.entries[0].flags & UInt16(FSE_SYMLINK) != 0)
    #expect(d.pointee.entries[2].flags & UInt16(FSE_SYMLINK) == 0)

    let all = try t.read(hidden: true); defer { fse_dir_free(all) }
    #expect(names(all).first == ".hidden")
    #expect(all.pointee.entries[0].flags & UInt16(FSE_HIDDEN) != 0)
}

@Test func emptyDirectory() throws {
    let t = try TempDir(); defer { t.cleanup() }
    let d = try t.read(); defer { fse_dir_free(d) }
    #expect(d.pointee.count == 0)
}

@Test func errors() throws {
    let t = try TempDir(); defer { t.cleanup() }
    var err: Int32 = 0
    #expect(fse_dir_read("/definitely/not/here", nil, &err) == nil)
    #expect(err == ENOENT)
    try t.touch("f")
    #expect(fse_dir_read(t.url.appendingPathComponent("f").path, nil, &err) == nil)
    #expect(err == ENOTDIR)
}

@Test func largeDirectory() throws {
    let t = try TempDir(); defer { t.cleanup() }
    let n = 20_000
    for i in 0..<n { try t.touch("entry-\(i)") }
    let d = try t.read(); defer { fse_dir_free(d) }
    #expect(Int(d.pointee.count) == n)
    #expect(String(cString: fse_entry_name(d, 0)) == "entry-0")
    #expect(String(cString: fse_entry_name(d, 1)) == "entry-1")
    #expect(String(cString: fse_entry_name(d, UInt32(n - 1))) == "entry-\(n - 1)")
    #expect(fse_dir_memory(d) < n * 80)
}

@Test func nameCompare() {
    #expect(fse_name_compare("a", "B") < 0)
    #expect(fse_name_compare("img2", "img10") < 0)
    #expect(fse_name_compare("img002", "img10") < 0)
    #expect(fse_name_compare("same", "same") == 0)
    #expect(fse_name_compare("Same", "same") != 0)
    #expect(fse_name_compare("b", "a") > 0)
}
