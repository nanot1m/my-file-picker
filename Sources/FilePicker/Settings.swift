import AppKit
import Carbon.HIToolbox

struct HotKeySetting: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = HotKeySetting(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let f = event.modifierFlags
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        carbonModifiers = m
    }

    var hasModifiers: Bool { carbonModifiers != 0 }

    var display: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + " " + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [UInt32: String] = [
            49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 53: "Esc", 51: "Delete", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        ]
        if let name = special[code] { return name }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(code)"
        }
        let data = unsafeBitCast(layoutData, to: CFData.self) as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { buf -> OSStatus in
            UCKeyTranslate(buf.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self), UInt16(code),
                           UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

enum Settings {
    static let hotKeyChanged = Notification.Name("FilePicker.hotKeyChanged")
    private static let keyCodeKey = "hotKeyCode"
    private static let modifiersKey = "hotKeyModifiers"

    static var hotKey: HotKeySetting {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: keyCodeKey) != nil else { return .default }
            return HotKeySetting(keyCode: UInt32(d.integer(forKey: keyCodeKey)),
                                 carbonModifiers: UInt32(d.integer(forKey: modifiersKey)))
        }
        set {
            let d = UserDefaults.standard
            d.set(Int(newValue.keyCode), forKey: keyCodeKey)
            d.set(Int(newValue.carbonModifiers), forKey: modifiersKey)
            NotificationCenter.default.post(name: hotKeyChanged, object: nil)
        }
    }
}
