//
//  ShortcutNames.swift
//  Kwota
//

import Foundation

/// String identifiers used to key persisted hotkey definitions in
/// `HotKeyStore` and (for `openPopup`) registrations in `HotKeyManager`.
enum ShortcutNames {
    /// Global hotkey: open the menu-bar popup.
    static let openPopup = "openPopup"
    static let nextProfile = "nextProfile"
    static let previousProfile = "previousProfile"
    static let nextTab = "nextTab"
    static let previousTab = "previousTab"

    /// Per-profile switch shortcut. Local-only (handled in `MenuBarView`
    /// via SwiftUI `.keyboardShortcut`); the string is just a stable key
    /// for `HotKeyStore`.
    static func switchProfile(id: UUID) -> String {
        "switchProfile.\(id.uuidString)"
    }

    static func switchTab(_ tab: MenuBarViewModel.Tab) -> String {
        "switchTab.\(tab.rawValue)"
    }
}
