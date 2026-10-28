import AppKit

final class LauncherPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum KeyAction {
    case up, down, enter, parent, escape, copyPath, openWith

    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch (event.keyCode, mods) {
        case (0x7E, []): self = .up
        case (0x7D, []): self = .down
        case (0x7C, []): self = .enter
        case (0x7B, []): self = .parent
        case (0x24, []), (0x4C, []): self = .enter
        case (0x35, []): self = .escape
        case (0x08, [.command]): self = .copyPath
        case (0x1F, [.command, .shift]): self = .openWith
        default: return nil
        }
    }
}

final class FileTableView: NSTableView {
    var onKeyAction: ((KeyAction) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if let action = KeyAction(event: event), onKeyAction?(action) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = KeyAction(event: event), onKeyAction?(action) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class FileCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizesSubviews = true
        icon.imageScaling = .scaleProportionallyDown
        icon.frame = NSRect(x: 10, y: (frame.height - 18) / 2, width: 18, height: 18)
        icon.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 13)
        label.frame = NSRect(x: 36, y: (frame.height - 17) / 2, width: frame.width - 46, height: 17)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, image: NSImage) {
        label.stringValue = name
        icon.image = image
    }
}
