//
//  PollingMode.swift
//  Kwota
//

import Foundation

enum PollingMode: String, CaseIterable, Identifiable {
    case normal
    case batterySaver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal:        return "Normal"
        case .batterySaver:  return "Battery saver"
        }
    }

    var openInterval: TimeInterval {
        switch self {
        case .normal:       return 120
        case .batterySaver: return 300
        }
    }

    var closedInterval: TimeInterval {
        switch self {
        case .normal:       return 900
        case .batterySaver: return 3600
        }
    }

    static func resolve(_ raw: String?) -> PollingMode {
        guard let raw, let m = PollingMode(rawValue: raw) else { return .normal }
        return m
    }
}
