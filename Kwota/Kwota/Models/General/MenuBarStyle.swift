//
//  MenuBarStyle.swift
//  Kwota
//

import Foundation

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case original
    case fillBackground
    case percentText
    case percentRing
    case tintDot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original:       return "Original"
        case .fillBackground: return "Fill background"
        case .percentText:    return "Percent text"
        case .percentRing:    return "Percent ring"
        case .tintDot:        return "Status dot"
        }
    }

    var requiresUsageSource: Bool { self != .original }

    /// Tolerant resolver — used by `@AppStorage` reads where the persisted
    /// rawValue could be unset or stale. Defaults to `.original`.
    static func resolve(_ raw: String?) -> MenuBarStyle {
        guard let raw, let style = MenuBarStyle(rawValue: raw) else { return .original }
        return style
    }
}
