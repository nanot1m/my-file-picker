import AppKit

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

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
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
        let text = isRecording ? "Type shortcut, Esc to cancel" : shortcut.display
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
    var onRecordingChanged: ((Bool) -> Void)?

    init() {
        let size = NSSize(width: 380, height: 150)
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
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(recorder)
    }

    func showError(_ text: String) {
        errorLabel.stringValue = text
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
    }

    @objc private func resetShortcut() {
        recorder.shortcut = .default
        Settings.hotKey = .default
    }

    override func cancelOperation(_ sender: Any?) {
        window?.close()
    }
}
