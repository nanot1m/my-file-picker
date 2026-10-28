import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let launcher = LauncherController()
    private let updater = Updater()
    private lazy var settings = SettingsWindowController(updater: updater)
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "File Picker")
        let menu = NSMenu()
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit File Picker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(registerHotKey), name: Settings.hotKeyChanged, object: nil)
        settings.onRecordingChanged = { [weak self] recording in
            if recording { self?.hotKey = nil } else { self?.registerHotKey() }
        }
        launcher.openSettings = { [weak self] in self?.openSettings() }
        registerHotKey()
        launcher.prepare()
        updater.startPeriodicChecks()
    }

    @objc private func checkForUpdates() {
        updater.check(userInitiated: true) { [weak self] result in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            switch result {
            case .success(let release?):
                alert.messageText = "File Picker \(release.version) is available"
                alert.informativeText = "You have \(Updater.currentVersion)." + (release.notes.isEmpty ? "" : "\n\n" + release.notes.prefix(600))
                alert.addButton(withTitle: Updater.isDevelopmentBuild ? "Open Release Page" : "Install and Relaunch")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    if Updater.isDevelopmentBuild { NSWorkspace.shared.open(release.pageURL) } else { self.updater.install(release) }
                }
            case .success(nil):
                alert.messageText = "You're up to date"
                alert.informativeText = "File Picker \(Updater.currentVersion) is the latest version."
                alert.runModal()
            case .failure(let error):
                alert.messageText = "Could not check for updates"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc private func registerHotKey() {
        let setting = Settings.hotKey
        hotKey = nil
        hotKey = HotKey(keyCode: setting.keyCode, modifiers: setting.carbonModifiers) { [weak self] in
            self?.launcher.toggle()
        }
        toggleItem.title = "Toggle Launcher (\(setting.display))"
        if hotKey == nil {
            settings.showError("Could not register \(setting.display); another app may own it. Pick a different shortcut.")
            if !(settings.window?.isVisible ?? false) { settings.show() }
        }
    }

    @objc private func toggle() { launcher.toggle() }

    @objc private func openSettings() {
        launcher.hideIfVisible()
        settings.show()
    }
}
