//
//  HotKeyDefinition.swift
//  Kwota
//

import AppKit

/// Persisted shape of a user-bound hotkey. `keyCode` is the AppKit virtual
/// keycode (the same value `NSEvent.keyCode` produces). `modifiers` is the
/// raw value of `NSEvent.ModifierFlags`, narrowed at construction to the
/// hotkey-relevant subset of `deviceIndependentFlagsMask` so we don't
/// persist volatile bits like Caps Lock or numeric-pad.
struct HotKeyDefinition: Codable, Equatable, Hashable {
    /// Modifier bits that meaningfully participate in a global hotkey.
    /// Subset of `NSEvent.ModifierFlags.deviceIndependentFlagsMask` that
    /// excludes `.capsLock`, `.numericPad`, `.help`, and `.function`.
    static let hotkeyModifierMask: NSEvent.ModifierFlags = [
        .command, .option, .control, .shift,
    ]

    let keyCode: UInt16
    let modifiers: UInt

    init(keyCode: UInt16, rawModifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = Self.normalize(rawModifiers: rawModifiers).rawValue
    }

    var nsModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    func matches(keyCode: UInt16, rawModifiers: UInt) -> Bool {
        self.keyCode == keyCode
            && modifiers == Self.normalize(rawModifiers: rawModifiers).rawValue
    }

    private static func normalize(rawModifiers: UInt) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: rawModifiers)
            .intersection(Self.hotkeyModifierMask)
    }
}
