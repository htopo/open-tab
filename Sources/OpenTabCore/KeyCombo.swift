import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The modifier keys a shortcut can require.
///
/// Stored as a raw bitmask so the settings file stays readable and stable; the
/// `CGEventFlags` values are not appropriate to persist because they carry
/// device-dependent bits.
public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ModifierSet(rawValue: 1 << 0)
    public static let option  = ModifierSet(rawValue: 1 << 1)
    public static let control = ModifierSet(rawValue: 1 << 2)
    public static let shift   = ModifierSet(rawValue: 1 << 3)

    /// Built from a live event's flags, ignoring caps lock, fn, and the
    /// left/right distinction bits that would otherwise make ⌘ and ⌘ unequal.
    public init(eventFlags: CGEventFlags) {
        var set = ModifierSet()
        if eventFlags.contains(.maskCommand)   { set.insert(.command) }
        if eventFlags.contains(.maskAlternate) { set.insert(.option) }
        if eventFlags.contains(.maskControl)   { set.insert(.control) }
        if eventFlags.contains(.maskShift)     { set.insert(.shift) }
        self = set
    }

    public var eventFlags: CGEventFlags {
        var flags = CGEventFlags()
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.option)  { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.shift)   { flags.insert(.maskShift) }
        return flags
    }

    /// Symbols in the order macOS displays them: ⌃⌥⇧⌘.
    public var displayString: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option)  { result += "⌥" }
        if contains(.shift)   { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }

    public var isEmpty: Bool { rawValue == 0 }
}

/// A modifier-plus-key binding.
///
/// The modifier set is what the user *holds*; the key is what they *press*. That
/// split matters for this app specifically: the switcher stays open for as long
/// as the modifiers are down, so a binding with no modifiers cannot express the
/// hold-and-cycle interaction at all.
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    /// A virtual key code, layout independent. `kVK_Tab` is 48 on every keyboard.
    public var keyCode: UInt16
    public var modifiers: ModifierSet

    public init(keyCode: UInt16, modifiers: ModifierSet) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌘Tab — the default first shortcut.
    public static let commandTab = KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: .command)

    /// ⌥` — the default second shortcut.
    public static let optionBacktick = KeyCombo(keyCode: UInt16(kVK_ANSI_Grave), modifiers: .option)

    /// Whether this binding can drive a hold-and-cycle switcher.
    public var isUsableAsHoldShortcut: Bool { !modifiers.isEmpty }

    public var displayString: String {
        modifiers.displayString + KeyCodes.displayName(for: keyCode)
    }

    /// Matches a live key event.
    ///
    /// Shift is excluded from the comparison because ⇧ is the reverse-direction
    /// modifier while the switcher is open: ⌘Tab and ⌘⇧Tab must both match a
    /// binding of ⌘Tab, or cycling backwards would close the overlay.
    public func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard self.keyCode == keyCode else { return false }
        let pressed = ModifierSet(eventFlags: flags).subtracting(.shift)
        return pressed == modifiers.subtracting(.shift)
    }
}

/// Virtual key code to display name.
public enum KeyCodes {

    /// Keys whose names are not derivable from the keyboard layout.
    private static let specialNames: [UInt16: String] = [
        UInt16(kVK_Return):        "↩",
        UInt16(kVK_Tab):           "⇥",
        UInt16(kVK_Space):         "Space",
        UInt16(kVK_Delete):        "⌫",
        UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_Escape):        "⎋",
        UInt16(kVK_LeftArrow):     "←",
        UInt16(kVK_RightArrow):    "→",
        UInt16(kVK_UpArrow):       "↑",
        UInt16(kVK_DownArrow):     "↓",
        UInt16(kVK_Home):          "↖",
        UInt16(kVK_End):           "↘",
        UInt16(kVK_PageUp):        "⇞",
        UInt16(kVK_PageDown):      "⇟",
        UInt16(kVK_Help):          "Help",
        UInt16(kVK_F1):  "F1",  UInt16(kVK_F2):  "F2",  UInt16(kVK_F3):  "F3",
        UInt16(kVK_F4):  "F4",  UInt16(kVK_F5):  "F5",  UInt16(kVK_F6):  "F6",
        UInt16(kVK_F7):  "F7",  UInt16(kVK_F8):  "F8",  UInt16(kVK_F9):  "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
    ]

    /// A human-readable name for a key.
    ///
    /// Printable keys are resolved through the *current keyboard layout*, so a
    /// French user recording what is physically the Q key sees "A". Hard-coding a
    /// US table here would mislabel every non-US keyboard.
    public static func displayName(for keyCode: UInt16) -> String {
        if let special = specialNames[keyCode] { return special }
        if let character = character(for: keyCode) { return character.uppercased() }
        return "Key \(keyCode)"
    }

    /// The character a key produces with no modifiers on the current layout.
    public static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return nil }

            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)

            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,                                   // no modifiers
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )

            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}
