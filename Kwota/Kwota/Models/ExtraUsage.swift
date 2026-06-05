//
//  ExtraUsage.swift
//  Kwota
//

import Foundation

struct ExtraUsage: Codable, Equatable {
    let isEnabled: Bool
    let utilization: Double?
    let usedCredits: Double?
    let monthlyLimit: Double?

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case utilization
        case usedCredits = "used_credits"
        case monthlyLimit = "monthly_limit"
    }

    /// `usedCredits` is in minor units (cents). Convert to dollars for display.
    var usedDollars: Double? { usedCredits.map { $0 / 100.0 } }
    var limitDollars: Double? { monthlyLimit.map { $0 / 100.0 } }
}
