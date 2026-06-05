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
        let value: Double?
        switch source {
        case .session:
            value = summary.primary?.utilization
        case .weekly:
            value = summary.secondary?.utilization
        case .higher:
            switch (summary.primary?.utilization, summary.secondary?.utilization) {
            case let (p?, s?): value = max(p, s)
            case let (p?, nil): value = p
            case let (nil, s?): value = s
            case (nil, nil):    value = nil
            }
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
