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
        case .normal:       return 60
        case .batterySaver: return 120
        }
    }

    var closedInterval: TimeInterval {
        switch self {
        case .normal:       return 600
        case .batterySaver: return 1800
        }
    }

    static func resolve(_ raw: String?) -> PollingMode {
        guard let raw, let m = PollingMode(rawValue: raw) else { return .normal }
        return m
    }
}
