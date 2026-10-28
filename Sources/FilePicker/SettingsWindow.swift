import AppKit
import ApplicationServices

final class ShortcutRecorder: NSView {
    var shortcut: HotKeySetting { didSet { needsDisplay = true } }
    var onChange: ((HotKeySetting) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private(set) var isRecording = false {
        didSet {
            needsDisplay = true
            if oldValue != isRecording { onRecordingChanged?(isRecording) }
        }
    }

    init(frame: NSRect, shortcut: HotKeySetting) {
        self.shortcut = shortcut
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Only focusable while recording, so opening the window never arms it by accident.
    override var acceptsFirstResponder: Bool { isRecording }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    override func mouseDown(with event: NSEvent) { arm() }

    private func arm() {
        if isRecording { return }
        isRecording = true
        if window?.makeFirstResponder(self) != true { isRecording = false }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Toggle launcher shortcut, \(shortcut.display)" }
    override func accessibilityPerformPress() -> Bool {
        arm()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            isRecording = false
            return
        }
        let candidate = HotKeySetting(event: event)
        let isFunctionKey = event.modifierFlags.contains(.function) && !(123...126).contains(event.keyCode)
        guard candidate.hasModifiers || isFunctionKey else { NSSound.beep(); return }
        shortcut = candidate
        isRecording = false
        onChange?(candidate)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
        let text = isRecording ? "Type shortcut, Esc to cancel" : shortcut.display + "  ·  click to change"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: isRecording ? .regular : .medium),
            .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}

final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 0x0D, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command] {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let recorder: ShortcutRecorder
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let grantButton = NSButton(title: "Grant…", target: nil, action: nil)
    private var statusTimer: Timer?
    private let updater: Updater
    private let updateStatus = NSTextField(labelWithString: "")
    private let checkButton = NSButton(title: "Check Now", target: nil, action: nil)
    private let autoUpdateBox = NSButton(checkboxWithTitle: "Install updates automatically", target: nil, action: nil)
    var onRecordingChanged: ((Bool) -> Void)?

    init(updater: Updater) {
        self.updater = updater
        let size = NSSize(width: 380, height: 300)
        let window = SettingsWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "File Picker Settings"
        window.isReleasedWhenClosed = false
        recorder = ShortcutRecorder(frame: NSRect(x: 160, y: size.height - 52, width: 200, height: 28), shortcut: Settings.hotKey)
        super.init(window: window)
        window.delegate = self

        let content = window.contentView!
        let label = NSTextField(labelWithString: "Toggle launcher")
        label.frame = NSRect(x: 20, y: size.height - 48, width: 130, height: 20)
        label.alignment = .right
        content.addSubview(label)
        content.addSubview(recorder)

        let reset = NSButton(title: "Reset to ⌥ Space", target: self, action: #selector(resetShortcut))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        reset.frame = NSRect(x: 158, y: size.height - 82, width: 140, height: 24)
        content.addSubview(reset)

        let axLabel = NSTextField(labelWithString: "Accessibility")
        axLabel.frame = NSRect(x: 20, y: size.height - 124, width: 130, height: 20)
        axLabel.alignment = .right
        content.addSubview(axLabel)

        accessibilityStatus.frame = NSRect(x: 160, y: size.height - 124, width: 120, height: 20)
        content.addSubview(accessibilityStatus)

        grantButton.target = self
        grantButton.action = #selector(grantAccessibility)
        grantButton.bezelStyle = .rounded
        grantButton.controlSize = .small
        grantButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        grantButton.frame = NSRect(x: 280, y: size.height - 127, width: 80, height: 24)
        content.addSubview(grantButton)

        let axHint = NSTextField(wrappingLabelWithString: "Needed only for “Paste into app” (⌘⇧V).")
        axHint.frame = NSRect(x: 160, y: size.height - 160, width: 200, height: 32)
        axHint.font = .systemFont(ofSize: 11)
        axHint.textColor = .secondaryLabelColor
        content.addSubview(axHint)

        let upLabel = NSTextField(labelWithString: "Updates")
        upLabel.frame = NSRect(x: 20, y: size.height - 200, width: 130, height: 20)
        upLabel.alignment = .right
        content.addSubview(upLabel)

        updateStatus.frame = NSRect(x: 160, y: size.height - 200, width: 120, height: 20)
        updateStatus.font = .systemFont(ofSize: 12)
        updateStatus.lineBreakMode = .byTruncatingTail
        content.addSubview(updateStatus)

        checkButton.target = self
        checkButton.action = #selector(checkForUpdates)
        checkButton.bezelStyle = .rounded
        checkButton.controlSize = .small
        checkButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        checkButton.frame = NSRect(x: 280, y: size.height - 203, width: 80, height: 24)
        content.addSubview(checkButton)

        autoUpdateBox.target = self
        autoUpdateBox.action = #selector(toggleAutoUpdate)
        autoUpdateBox.controlSize = .small
        autoUpdateBox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        autoUpdateBox.frame = NSRect(x: 158, y: size.height - 226, width: 210, height: 20)
        content.addSubview(autoUpdateBox)

        let upHint = NSTextField(wrappingLabelWithString: "Checks GitHub Releases every 6 hours. Version \(Updater.currentVersion).")
        upHint.frame = NSRect(x: 160, y: size.height - 250, width: 200, height: 20)
        upHint.font = .systemFont(ofSize: 11)
        upHint.textColor = .secondaryLabelColor
        content.addSubview(upHint)

        NotificationCenter.default.addObserver(self, selector: #selector(refreshUpdateStatus), name: Updater.statusChanged, object: nil)

        errorLabel.frame = NSRect(x: 20, y: 14, width: size.width - 40, height: 34)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        content.addSubview(errorLabel)

        recorder.onChange = { shortcut in Settings.hotKey = shortcut }
        recorder.onRecordingChanged = { [weak self] recording in self?.onRecordingChanged?(recording) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        recorder.shortcut = Settings.hotKey
        errorLabel.stringValue = ""
        refreshAccessibilityStatus()
        refreshUpdateStatus()
        autoUpdateBox.state = Updater.autoUpdateEnabled ? .on : .off
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshAccessibilityStatus()
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
    }

    func showError(_ text: String) {
        errorLabel.stringValue = text
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func refreshAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        accessibilityStatus.stringValue = trusted ? "Granted" : "Not granted"
        accessibilityStatus.textColor = trusted ? .systemGreen : .secondaryLabelColor
        grantButton.isEnabled = !trusted
    }

    @objc private func refreshUpdateStatus() {
        updateStatus.stringValue = updater.status.text
        updateStatus.toolTip = updater.status.text
        if case .available(let v) = updater.status, !Updater.isDevelopmentBuild {
            checkButton.title = "Install \(v)"
        } else {
            checkButton.title = "Check Now"
        }
    }

    @objc private func checkForUpdates() {
        if case .available = updater.status, let release = updater.latest, !Updater.isDevelopmentBuild {
            updater.install(release)
        } else {
            updater.check(userInitiated: true)
        }
    }

    @objc private func toggleAutoUpdate() {
        Updater.autoUpdateEnabled = autoUpdateBox.state == .on
    }

    @objc private func grantAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options) else { return refreshAccessibilityStatus() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func resetShortcut() {
        recorder.shortcut = .default
        Settings.hotKey = .default
    }

    override func cancelOperation(_ sender: Any?) {
        window?.close()
    }
}
