//
//  MenuBarUsageDriver.swift
//  Kwota
//

import SwiftUI

struct MenuBarReading: Equatable {
    let utilization: Double?   // 0...100, nil when no data
    let tint: Color
}

enum MenuBarUsageDriver {
    static func read(summary: ProviderUsageSummary?, source: MenuBarUsageSource) -> MenuBarReading {
        guard let summary else {
            return MenuBarReading(utilization: nil, tint: UsageLevel.tint(for: nil))
        }
        let primary = summary.primary?.utilization
        let secondary = summary.secondary?.utilization
        let value: Double?
        switch source {
        case .session:
            // Prefer the 5-hour window; fall back to weekly when the provider
            // exposes no session window. Codex (after OpenAI collapsed to a
            // single weekly window) has a nil primary, so without the fallback
            // the icon would read "no usage" and stay neutral despite a real
            // weekly load. Falling back keeps the icon colored by the account's
            // only active limit rather than blanking it.
            value = primary ?? secondary
        case .weekly:
            value = secondary ?? primary
        case .higher:
            value = [primary, secondary].compactMap { $0 }.max()
        }
        return MenuBarReading(utilization: value, tint: UsageLevel.tint(for: value))
    }
}

extension MenuBarUsageDriver {
    /// Fraction of quota still remaining, mapped to 0...1 for the
    /// fill-background variant. The fill represents *headroom*, not usage,
    /// so the pill starts full at 0% utilization and shrinks toward empty
    /// as utilization climbs to 100%. `nil` (no data) → 0 (no fill).
    static func remainingFraction(for utilization: Double?) -> CGFloat {
        guard let u = utilization else { return 0 }
        return CGFloat(max(0, min(100, 100 - u)) / 100)
    }
}
