//
//  MenuBarPulse.swift
//  Kwota
//

import Foundation

/// Decides whether the menu-bar icon should pulse to draw attention to a
/// near-exhausted quota. Pure predicate so it can be unit-tested without
/// touching SwiftUI.
///
/// The pulse is reserved for styles that already carry a tint signal —
/// fill-background and tint-dot. Styles the user chose specifically for a
/// quieter readout (original / percent text / percent ring) are left
/// untouched so the choice survives.
enum MenuBarPulse {
    /// Pulse kicks in at the same utilization where `UsageLevel.tint`
    /// switches to red — keeps the visual escalation consistent across the
    /// app.
    static let threshold: Double = UsageLevel.criticalThreshold

    static func shouldPulse(style: MenuBarStyle, utilization: Double?) -> Bool {
        guard style == .fillBackground || style == .tintDot else { return false }
        guard let u = utilization else { return false }
        return u >= threshold
    }
}
