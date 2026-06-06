//
//  NotificationSettings.swift
//  Kwota
//

import Foundation

/// Global notification preferences. Applied to whichever profile is
/// currently active; per-profile opt-out lives on `Profile.notificationsMuted`.
struct NotificationSettings: Codable, Equatable {
    var shortWindowThresholds: Set<Int>   // subset of {75, 90, 100}
    var longWindowThresholds:  Set<Int>
    var notifyOnReset:         Bool
    var notifyOnTokenExpiry:   Bool

    static let `default` = NotificationSettings(
        shortWindowThresholds: [100],
        longWindowThresholds:  [100],
        notifyOnReset:         false,
        notifyOnTokenExpiry:   true
    )
}
