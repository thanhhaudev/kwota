//
//  UsageUrgency.swift
//  Kwota
//
//  Maps remaining quota (0–100, the app-wide "% remaining" convention) to a
//  three-step urgency level and its meter color. Pure so the thresholds are
//  unit-testable without a SwiftUI host. Compact mode colors meters by urgency
//  instead of by metric category, so a glance reads "how close to the cap".
//

import SwiftUI

enum UsageUrgency {
    case ok        // healthy headroom
    case watch     // getting close
    case critical  // little left

    static let watchFloor: Double = 15
    static let okFloor: Double = 40

    init(remaining: Double) {
        if remaining >= Self.okFloor {
            self = .ok
        } else if remaining >= Self.watchFloor {
            self = .watch
        } else {
            self = .critical
        }
    }

    /// 0–100 USED convention: remaining = 100 − used, clamped. `nil` used has no
    /// urgency (caller renders a dimmed track).
    init?(utilization: Double?) {
        guard let utilization else { return nil }
        let remaining = max(0, min(100, 100 - utilization))
        self.init(remaining: remaining)
    }

    var color: Color {
        switch self {
        case .ok:       return .green
        case .watch:    return .orange
        case .critical: return .red
        }
    }
}
