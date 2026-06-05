//
//  DockIconMode.swift
//  Kwota
//

import Foundation

enum DockIconMode: String, CaseIterable, Identifiable, Codable {
    case alwaysHide
    case alwaysShow
    case auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alwaysHide: return "Always hide"
        case .alwaysShow: return "Always show"
        case .auto:       return "Auto"
        }
    }
}

/// Non-view wrapper around UserDefaults for `DockIconMode`. Views use
/// `@AppStorage(DockIconModeStore.key)` directly; controllers use this.
final class DockIconModeStore {
    static let key = "settings.dockIconMode"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var mode: DockIconMode {
        get {
            guard let raw = defaults.string(forKey: Self.key),
                  let mode = DockIconMode(rawValue: raw) else { return .auto }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }
}
