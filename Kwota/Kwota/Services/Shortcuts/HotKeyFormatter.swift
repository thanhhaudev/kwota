//
//  HotKeyFormatter.swift
//  Kwota
//

import AppKit

/// Pure `(HotKeyDefinition) -> String` formatter for displaying user-bound
/// hotkeys in canonical macOS form: ⌃⌥⇧⌘<key>.
///
/// Keycodes are physical positions (stable across keyboard layouts), so we
/// label them by their ANSI/QWERTY name. For unknown codes we fall back
/// to `#<keycode>` so the recorder still shows _something_.
enum HotKeyFormatter {
    static func string(for definition: HotKeyDefinition) -> String {
        modifierString(definition.nsModifiers) + keyString(for: definition.keyCode)
    }

    static func modifierString(_ flags: NSEvent.ModifierFlags) -> String {
        // Canonical macOS order: ⌃ ⌥ ⇧ ⌘
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    static func keyString(for keyCode: UInt16) -> String {
        if let label = keyCodeMap[keyCode] { return label }
        return "#\(keyCode)"
    }

    // MARK: - Map

    private static let keyCodeMap: [UInt16: String] = [
        // Letters (ANSI layout — physical positions)
        0: "A",  1: "S",  2: "D",  3: "F",  4: "H",  5: "G",  6: "Z",
        7: "X",  8: "C",  9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
       15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
       37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        // Top-row digits
       18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
       26: "7", 28: "8", 25: "9", 29: "0",
        // Punctuation
       24: "=", 27: "-", 30: "]", 33: "[", 39: "'",
       41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        // Whitespace + edits
       36: "↩",         // Return
       48: "⇥",         // Tab
       49: "Space",
       51: "⌫",         // Delete (backspace)
       53: "⎋",         // Escape
       117: "⌦",        // Forward Delete
        // Arrows
      123: "←", 124: "→", 125: "↓", 126: "↑",
        // Function keys
      122: "F1", 120: "F2", 99:  "F3", 118: "F4", 96:  "F5",
       97: "F6", 98:  "F7", 100: "F8", 101: "F9", 109: "F10",
      103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        // Misc
      114: "Help", 115: "Home", 116: "PageUp", 119: "End", 121: "PageDown"
    ]
}
