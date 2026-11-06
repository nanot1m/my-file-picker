import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FSEngine

/// Plain-text diagnostics for bug reports. Contains no file names from the user's folders, only counts and timings.
enum DebugReport {
    static func generate(updater: Updater, completion: @escaping (URL) -> Void) {
        var lines: [String] = []
        let home = NSHomeDirectory()
        func add(_ s: String) { lines.append(s) }
        func section(_ title: String) { add(""); add("== \(title) ==") }
        func abbreviate(_ path: String) -> String { path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path }

        add("File Picker debug report")
        add("Generated: \(ISO8601DateFormatter().string(from: Date()))")

        section("App")
        let bundle = Bundle.main
        add("Version: \(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
        add("Bundle path: \(abbreviate(bundle.bundlePath))")
        add("Development build: \(Updater.isDevelopmentBuild)")
        add("Signature: \(shell("/usr/bin/codesign", ["-dvv", bundle.bundlePath]).split(separator: "\n").filter { $0.hasPrefix("Authority=") || $0.hasPrefix("TeamIdentifier=") || $0.hasPrefix("Identifier=") }.joined(separator: " | "))")
        add("System uptime: \(Int(ProcessInfo.processInfo.systemUptime) / 3600) h")

        section("System")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        add("macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        add("Hardware: \(shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).trimmingCharacters(in: .whitespacesAndNewlines)), \(ProcessInfo.processInfo.physicalMemory / (1 << 30)) GB")
        add("Displays: \(NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\($0.backingScaleFactor)x" }.joined(separator: ", "))")
        add("Appearance: \(NSApp.effectiveAppearance.name.rawValue)")
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
            add("Keyboard layout: \(Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String)")
        }

        section("Settings")
        add("Hotkey: \(Settings.hotKey.display)")
        add("Preview column: \(UserDefaults.standard.bool(forKey: "previewEnabled"))")
        add("Favorites shown: \(Pins.enabled), count: \(Pins.favorites.count)")
        let sorts = UserDefaults.standard.dictionary(forKey: "folderSorts") as? [String: Int] ?? [:]
        add("Custom folder sorts: \(sorts.count)")
        add("Auto-update: \(Updater.autoUpdateEnabled), status: \(updater.status.text)")
        let lastCheck = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        add("Last update check: \(lastCheck > 0 ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: lastCheck)) : "never")")

        section("Permissions")
        add("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")")
        for folder in ["Desktop", "Documents", "Downloads"] {
            var err: Int32 = 0
            var opts = fse_options(include_hidden: 0, sort: 0)
            if let d = fse_dir_read(home + "/" + folder, &opts, &err) { add("\(folder): readable (\(d.pointee.count) items)"); fse_dir_free(d) }
            else { add("\(folder): \(DirectoryError(code: err).description)") }
        }
        add("iCloud Drive folder present: \(FileManager.default.fileExists(atPath: Pins.iCloudPath))")

        section("Spotlight")
        add(shell("/usr/bin/mdutil", ["-s", "/"]).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | "))

        section("Engine")
        var opts = fse_options(include_hidden: 0, sort: 0)
        var err: Int32 = 0
        if let d = fse_dir_read(home, &opts, &err) {
            add(String(format: "Home: %d items, read %.2f ms, sort %.2f ms, %d bytes", d.pointee.count, Double(d.pointee.read_ns) / 1e6, Double(d.pointee.sort_ns) / 1e6, fse_dir_memory(d)))
            fse_dir_free(d)
        } else { add("Home: \(DirectoryError(code: err).description)") }

        section("Recent timing events")
        lines += Perf.recentEvents.suffix(60)

        section("Recents probe")
        let t0 = Perf.now()
        VirtualFolders.recents(limit: 500) { virtual in
            let items = virtual.items
            add("Query time: \(String(format: "%.0f", Perf.ms(since: t0))) ms")
            add("Items after filtering: \(items.count)")
            if let newest = items.map(\.lastUsed).max(), let oldest = items.map(\.lastUsed).min() {
                add("Last-opened range: \(ISO8601DateFormatter().string(from: oldest)) … \(ISO8601DateFormatter().string(from: newest))")
            }
            let byParent = Dictionary(grouping: items) { abbreviate(($0.path as NSString).deletingLastPathComponent) }
            for (parent, group) in byParent.sorted(by: { $0.value.count > $1.value.count }).prefix(8) { add("  \(group.count) in \(parent)") }

            let name = "FilePicker-debug-\(Self.stamp()).txt"
            let url = URL(fileURLWithPath: home).appendingPathComponent("Desktop").appendingPathComponent(name)
            try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
            completion(url)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func shell(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return "(\(tool) failed: \(error.localizedDescription))" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
