import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let launcher = LauncherController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "File Picker")
        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Launcher (⌥ Space)", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit File Picker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.launcher.toggle()
        }
        if hotKey == nil {
            NSLog("Failed to register Option+Space; another app may own it.")
        }
        launcher.prepare()
    }

    @objc private func toggle() { launcher.toggle() }
}
