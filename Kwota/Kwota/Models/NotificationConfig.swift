//
//  NotificationConfig.swift
//  Kwota
//

import Foundation

/// Per-profile notification preferences. `nil` on a Profile means "feature
/// off" (legacy profiles). When the user toggles `enabled = true` for the
/// first time, the UI seeds the profile's config with `default`.
struct NotificationConfig: Codable, Equatable {
    var enabled: Bool
    var sessionThresholds: Set<Int>   // subset of {75, 90, 100}
    var weeklyThresholds: Set<Int>
    var notifyOnReset: Bool
    var notifyOnTokenExpiry: Bool

    static let `default` = NotificationConfig(
        enabled: false,
        sessionThresholds: [100],
        weeklyThresholds: [100],
        notifyOnReset: false,
        notifyOnTokenExpiry: true
    )
}
