import AppKit

/// The five shortcuts the user can rebind. Each knows its own default and its rules —
/// the global summon must carry a ⌘/⌃/⌥ modifier (a bare global key would fire on every
/// press system-wide), while panel-local shortcuts may be bare (translate is a plain ⏎).
enum ShortcutAction: String, CaseIterable, Identifiable {
    case summon, translate, newline, close, copy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .summon: return L("全局呼出")
        case .translate: return L("翻译")
        case .newline: return L("换行")
        case .close: return L("关闭 / 返回")
        case .copy: return L("复制")
        }
    }

    /// True only for the global hotkey, which is registered system-wide via Carbon.
    var isGlobal: Bool { self == .summon }

    /// The global hotkey needs a real modifier; local ones don't.
    var requiresModifier: Bool { isGlobal }

    var defaultCombo: KeyCombo {
        switch self {
        case .summon:
            return KeyCombo(keyCode: 49, modifiers: NSEvent.ModifierFlags([.option]).rawValue, display: "⌥Space")
        case .translate:
            return KeyCombo(keyCode: 36, modifiers: 0, display: "⏎")
        case .newline:
            return KeyCombo(keyCode: 36, modifiers: NSEvent.ModifierFlags([.command]).rawValue, display: "⌘⏎")
        case .close:
            return KeyCombo(keyCode: 53, modifiers: 0, display: "Esc")
        case .copy:
            return .defaultCopy
        }
    }
}

/// A user-recordable keyboard shortcut.
///
/// The display string is captured at record time rather than derived on the fly:
/// turning a keyCode back into a character requires the keyboard layout that was
/// active when the key was pressed, and that can change under us.
struct KeyCombo: Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var display: String

    static let defaultCopy = KeyCombo(
        keyCode: 8,  // C
        modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
        display: "⇧⌘C"  // Apple's canonical modifier order is ⌃⌥⇧⌘
    )

    func matches(_ event: NSEvent) -> Bool {
        Self.canonicalKeyCode(event.keyCode) == Self.canonicalKeyCode(keyCode)
            && Self.normalized(event.modifierFlags).rawValue == modifiers
    }

    /// Same key + same modifiers, ignoring the (derived) display string. Used for
    /// conflict detection and "is this still the default?" checks.
    static func sameKey(_ a: KeyCombo, _ b: KeyCombo) -> Bool {
        canonicalKeyCode(a.keyCode) == canonicalKeyCode(b.keyCode) && a.modifiers == b.modifiers
    }

    /// Return and the numeric-keypad Enter are the same key as far as shortcuts care.
    static func canonicalKeyCode(_ code: UInt16) -> UInt16 { code == 76 ? 36 : code }

    /// Caps lock is a state, not an intent — a shortcut shouldn't stop working because
    /// it happens to be on. Numeric-keypad key events always carry `.numericPad`
    /// regardless of which physical keys are held — without stripping it too, the
    /// keypad Enter (already unified with Return above) would never match a combo
    /// defined with the main Return key, and would fall through as a plain newline.
    /// `.function` gets the same treatment: Fn is a layer key, not an intent, so a
    /// combo recorded while Fn happens to be held must still match plain presses
    /// (and a combo recorded without it must match presses that carry Fn).
    static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    }

    static func describe(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + keyName(keyCode: keyCode, characters: characters)
    }

    private static func keyName(keyCode: UInt16, characters: String?) -> String {
        // Keys whose charactersIgnoringModifiers is a control code or invisible.
        switch keyCode {
        case 36, 76: return "⏎"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "⇞"
        case 121: return "⇟"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: break
        }
        guard let characters, let first = characters.first, first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol else {
            return "Key \(keyCode)"
        }
        return characters.uppercased()
    }
}
