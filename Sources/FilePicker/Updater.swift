import AppKit

struct ReleaseInfo {
    let version: String
    let zipURL: URL
    let pageURL: URL
    let notes: String
}

/// Checks GitHub Releases for a newer build and can replace the running bundle with it.
final class Updater {
    static let statusChanged = Notification.Name("FilePicker.updaterStatusChanged")
    static let autoUpdateKey = "autoUpdate"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let api = URL(string: "https://api.github.com/repos/nanot1m/my-file-picker/releases/latest")!
    private static let interval: TimeInterval = 6 * 60 * 60

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading(String)
        case installing
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "Not checked yet"
            case .checking: return "Checking…"
            case .upToDate: return "Up to date (\(Updater.currentVersion))"
            case .available(let v): return "Version \(v) available"
            case .downloading(let v): return "Downloading \(v)…"
            case .installing: return "Installing…"
            case .failed(let why): return "Update failed: \(why)"
            }
        }
    }

    private(set) var status: Status = .idle {
        didSet { NotificationCenter.default.post(name: Self.statusChanged, object: nil) }
    }
    private(set) var latest: ReleaseInfo?
    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var autoUpdateEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoUpdateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoUpdateKey) }
    }

    /// Development builds live under the repo's build/ folder and must not be replaced.
    static var isDevelopmentBuild: Bool {
        Bundle.main.bundlePath.contains("/build/") || Bundle.main.bundlePath.contains("/.build/")
    }

    func startPeriodicChecks() {
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 30, repeats: true) { [weak self] _ in self?.periodicCheck() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.periodicCheck() }
    }

    private func periodicCheck() {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > Self.interval else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool, completion: ((Result<ReleaseInfo?, Error>) -> Void)? = nil) {
        if case .checking = status { return }
        if case .downloading = status { return }
        status = .checking
        var request = URLRequest(url: Self.api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FilePicker/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                do {
                    if let error { throw error }
                    guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw UpdateError("GitHub returned \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    }
                    let release = try Self.parse(data)
                    if Self.isNewer(release.version, than: Self.currentVersion) {
                        self.latest = release
                        self.status = .available(release.version)
                        completion?(.success(release))
                        if !userInitiated, Self.autoUpdateEnabled, !Self.isDevelopmentBuild { self.install(release) }
                    } else {
                        self.latest = nil
                        self.status = .upToDate
                        completion?(.success(nil))
                    }
                } catch {
                    self.status = .failed(error.localizedDescription)
                    completion?(.failure(error))
                }
            }
        }.resume()
    }

    func install(_ release: ReleaseInfo) {
        if case .downloading = status { return }
        status = .downloading(release.version)
        URLSession.shared.downloadTask(with: release.zipURL) { [weak self] tempURL, response, error in
            guard let self else { return }
            do {
                if let error { throw error }
                guard let tempURL, (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("download failed") }
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent("FilePicker-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let zip = staging.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: tempURL, to: zip)
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
                let newApp = staging.appendingPathComponent("FilePicker.app")
                guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError("archive has no FilePicker.app") }
                try Self.verifySignature(of: newApp)
                DispatchQueue.main.async {
                    self.status = .installing
                    do {
                        try Self.replaceRunningBundle(with: newApp)
                        Self.relaunch()
                    } catch {
                        self.status = .failed(error.localizedDescription)
                    }
                }
            } catch {
                DispatchQueue.main.async { self.status = .failed(error.localizedDescription) }
            }
        }.resume()
    }

    // MARK: - Helpers

    private static func parse(_ data: Data) throws -> ReleaseInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]] else { throw UpdateError("unexpected response") }
        let zip = assets.compactMap { asset -> URL? in
            guard let name = asset["name"] as? String, name.hasSuffix(".zip"),
                  let url = asset["browser_download_url"] as? String else { return nil }
            return URL(string: url)
        }.first
        guard let zip else { throw UpdateError("release has no zip asset") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return ReleaseInfo(version: version, zipURL: zip, pageURL: page, notes: json["body"] as? String ?? "")
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return text
    }

    /// The new bundle must carry a valid signature, and the same Team ID as the running one when that has one.
    private static func verifySignature(of app: URL) throws {
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let currentTeam = teamIdentifier(of: Bundle.main.bundleURL)
        if let currentTeam, currentTeam != "not set" {
            guard teamIdentifier(of: app) == currentTeam else { throw UpdateError("signer does not match the installed app") }
        }
    }

    private static func teamIdentifier(of app: URL) -> String? {
        guard let info = try? run("/usr/bin/codesign", ["-dvv", app.path]) else { return nil }
        return info.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
    }

    private static func replaceRunningBundle(with newApp: URL) throws {
        let current = Bundle.main.bundleURL
        let fm = FileManager.default
        let backup = current.deletingLastPathComponent().appendingPathComponent(".FilePicker-previous.app")
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: current, to: backup)
        do {
            try fm.moveItem(at: newApp, to: current)
        } catch {
            try? fm.moveItem(at: backup, to: current)
            throw error
        }
        try? fm.removeItem(at: backup)
    }

    private static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
