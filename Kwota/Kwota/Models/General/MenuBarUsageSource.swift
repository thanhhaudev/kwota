//
//  MenuBarUsageSource.swift
//  Kwota
//

import Foundation

enum MenuBarUsageSource: String, CaseIterable, Identifiable {
    case session
    case weekly
    case higher

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: return "Session (5h)"
        case .weekly:  return "Weekly (7d)"
        case .higher:  return "Higher of two"
        }
    }

    static func resolve(_ raw: String?) -> MenuBarUsageSource {
        guard let raw, let s = MenuBarUsageSource(rawValue: raw) else { return .session }
        return s
    }
}
