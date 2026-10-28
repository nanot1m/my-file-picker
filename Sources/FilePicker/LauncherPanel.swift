import AppKit

final class LauncherPanel: NSPanel {
    var onCommand: ((Selector) -> Bool)?

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

    /// Matched by physical key so the shortcuts work under non-Latin keyboard layouts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function)
        let selector: Selector?
        switch (event.keyCode, mods) {
        case (0x24, [.command]), (0x4C, [.command]): selector = Selector(("showActions:"))
        case (0x08, [.command]): selector = #selector(NSText.copy(_:))
        case (0x08, [.command, .shift]): selector = Selector(("copyHomeRelativePath:"))
        case (0x1F, [.command, .shift]): selector = Selector(("openWith:"))
        case (0x0F, [.command]): selector = Selector(("renameSelection:"))
        case (0x33, [.command]): selector = Selector(("trashSelection:"))
        case (0x02, [.command]): selector = Selector(("duplicateSelection:"))
        case (0x2B, [.command]): selector = Selector(("openSettings:"))
        case (0x09, [.command]): selector = #selector(NSText.paste(_:))
        case (0x00, [.command]): selector = #selector(NSText.selectAll(_:))
        case (0x07, [.command]): selector = #selector(NSText.cut(_:))
        default: selector = nil
        }
        if let selector, onCommand?(selector) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

enum Masks {
    static func roundedRect(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
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

    func configure(name: String, image: NSImage, secondary: Bool = false) {
        label.stringValue = name
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        icon.image = image
    }
}

final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}
