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
        case (0x02, [.command]): selector = Selector(("duplicateSelection:"))
        case (0x2B, [.command]): selector = Selector(("openSettings:"))
        case (0x01, [.command]): selector = Selector(("toggleSelectionMode:"))
        case (0x01, [.command, .shift]): selector = Selector(("chooseSort:"))
        case (0x23, [.command]): selector = Selector(("togglePreview:"))
        case (0x09, [.command]): selector = #selector(NSText.paste(_:))
        case (0x09, [.command, .shift]): selector = Selector(("pasteIntoPreviousApp:"))
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

enum MarkState {
    case hidden, unmarked, marked
}

final class FileCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let mark = NSImageView()
    private static let markedImage = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Selected")
    private static let unmarkedImage = NSImage(systemSymbolName: "circle", accessibilityDescription: "Not selected")

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
        mark.frame = NSRect(x: 12, y: (frame.height - 16) / 2, width: 16, height: 16)
        mark.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
        mark.imageScaling = .scaleProportionallyDown
        mark.isHidden = true
        addSubview(icon)
        addSubview(label)
        addSubview(mark)
        imageView = icon
        textField = label
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, detail: String? = nil, image: NSImage, secondary: Bool = false, mark state: MarkState = .hidden) {
        if let detail {
            let text = NSMutableAttributedString(string: name, attributes: [.font: label.font!, .foregroundColor: NSColor.labelColor])
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
            label.attributedStringValue = text
        } else {
            label.stringValue = name
            label.textColor = secondary ? .secondaryLabelColor : .labelColor
        }
        icon.image = image
        mark.isHidden = state == .hidden
        mark.image = state == .marked ? Self.markedImage : Self.unmarkedImage
        mark.contentTintColor = state == .marked ? .controlAccentColor : .tertiaryLabelColor
        let shift: CGFloat = state == .hidden ? 0 : 26
        icon.frame.origin.x = 10 + shift
        label.frame.origin.x = 36 + shift
        label.frame.size.width = bounds.width - 46 - shift
    }
}

final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

struct Hint {
    let key: String
    let label: String
}

/// Bottom bar: keycap chips with labels on the left, status on the right. Items that don't fit are dropped whole.
final class HintsBar: NSView {
    var hints: [Hint] = [] { didSet { needsLayout = true; needsDisplay = true } }
    var status: String = "" { didSet { statusLabel.stringValue = status; statusLabel.toolTip = status; needsLayout = true } }

    private let statusLabel = NSTextField(labelWithString: "")
    private var statusWidth: CGFloat { bounds.width < 500 ? 80 : 130 }
    private let keyFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private let labelFont = NSFont.systemFont(ofSize: 11.5)
    private let gap: CGFloat = 12
    private let keyPad: CGFloat = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(statusLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        statusLabel.frame = NSRect(x: bounds.width - statusWidth - 14, y: (bounds.height - 16) / 2, width: statusWidth, height: 16)
    }

    private func keySize(_ key: String) -> NSSize {
        let s = key.size(withAttributes: [.font: keyFont])
        return NSSize(width: ceil(s.width) + keyPad * 2, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 14
        let limit = bounds.width - statusWidth - 28
        let midY = bounds.midY
        for hint in hints {
            let ks = keySize(hint.key)
            let ls = hint.label.size(withAttributes: [.font: labelFont])
            let total = ks.width + 5 + ceil(ls.width)
            if x + total > limit { break }
            let keyRect = NSRect(x: x, y: midY - ks.height / 2, width: ks.width, height: ks.height)
            let path = NSBezierPath(roundedRect: keyRect, xRadius: 4, yRadius: 4)
            NSColor.quaternaryLabelColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
            hint.key.draw(at: NSPoint(x: x + keyPad, y: midY - ks.height / 2 + 3),
                          withAttributes: [.font: keyFont, .foregroundColor: NSColor.labelColor])
            hint.label.draw(at: NSPoint(x: x + ks.width + 5, y: midY - ls.height / 2),
                            withAttributes: [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor])
            x += total + gap
        }
    }
}
