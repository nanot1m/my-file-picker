import FSEngine
import Foundation

func baselineReaddir(_ path: String) -> Int {
    guard let dir = opendir(path) else { return -1 }
    defer { closedir(dir) }
    let fd = dirfd(dir)
    var n = 0
    var st = stat()
    while let de = readdir(dir) {
        var name = de.pointee.d_name
        let count = withUnsafePointer(to: &name) { p -> Int in
            p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { c in
                if c[0] == 46 && (c[1] == 0 || (c[1] == 46 && c[2] == 0)) { return 0 }
                return fstatat(fd, c, &st, AT_SYMLINK_NOFOLLOW) == 0 ? 1 : 0
            }
        }
        n += count
    }
    return n
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: fsbench <directory> [iterations] [--hidden] [--baseline]")
    exit(2)
}
let path = args[1]
let iterations = args.count >= 3 ? Int(args[2]) ?? 5 : 5
let hidden = args.contains("--hidden")
let baseline = args.contains("--baseline")

var opts = fse_options(include_hidden: hidden ? 1 : 0)
var samples: [Double] = []
var count: UInt32 = 0
var memory = 0
var sortMs = 0.0

for _ in 0..<iterations {
    var err: Int32 = 0
    let t0 = fse_now_ns()
    guard let d = fse_dir_read(path, &opts, &err) else {
        print("error: \(String(cString: strerror(err)))")
        exit(1)
    }
    let total = Double(fse_now_ns() - t0) / 1e6
    samples.append(total)
    count = d.pointee.count
    memory = fse_dir_memory(d)
    sortMs = Double(d.pointee.sort_ns) / 1e6
    fse_dir_free(d)
}
samples.sort()
let median = samples[samples.count / 2]
print("fse_dir_read \(path)")
print(String(format: "  entries      %u (%.1f bytes/entry)", count, count > 0 ? Double(memory) / Double(count) : 0))
print(String(format: "  min          %.3f ms", samples[0]))
print(String(format: "  median       %.3f ms (sort %.3f ms)", median, sortMs))
print(String(format: "  max          %.3f ms", samples[samples.count - 1]))
print(String(format: "  per entry    %.0f ns", count > 0 ? median * 1e6 / Double(count) : 0))
print(String(format: "  memory       %.1f KB", Double(memory) / 1024))

if baseline {
    var bs: [Double] = []
    var n = 0
    for _ in 0..<iterations {
        let t0 = fse_now_ns()
        n = baselineReaddir(path)
        bs.append(Double(fse_now_ns() - t0) / 1e6)
    }
    bs.sort()
    print(String(format: "readdir+fstatat baseline: %d entries, median %.3f ms (%.2fx)", n, bs[bs.count / 2], bs[bs.count / 2] / median))
}
