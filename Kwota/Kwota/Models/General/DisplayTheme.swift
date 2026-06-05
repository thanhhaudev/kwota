//
//  DisplayTheme.swift
//  Kwota
//

import SwiftUI

/// User-facing override for the popover + Settings color scheme. The
/// menu-bar icon always tracks the system appearance — forcing it to
/// render against the wrong status-bar background produces a near-
/// invisible glyph.
enum DisplayTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Follow system"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// Maps to the `ColorScheme?` accepted by
    /// `View.preferredColorScheme(_:)`. `nil` means "no override".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Tolerant resolver — used by `@AppStorage` reads where the
    /// persisted string may be missing or stale.
    static func resolve(_ raw: String?) -> DisplayTheme {
        guard let raw, let v = DisplayTheme(rawValue: raw) else { return .system }
        return v
    }
}
