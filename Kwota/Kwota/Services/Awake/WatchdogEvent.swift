//
//  WatchdogEvent.swift
//  Kwota
//
//  Durable record of everything `AwakeWatchdog` observes. F-003 could not be
//  root-caused because the only trace was `AppLog`'s in-memory ring plus
//  os_log, and both had rotated by the time anyone looked. These records are
//  written to disk from the watchdog's own queue, before it touches the main
//  actor, so they survive a main actor that never recovers.
//

import Foundation

/// The watchdog's own mode enum rather than `AwakeSession.Mode`: this value
/// crosses to a non-isolated queue, and under this target's default MainActor
/// isolation the session type cannot.
nonisolated enum WatchdogMode: String, Codable, Equatable, Sendable {
    case auto, manual
}

nonisolated struct WatchdogFiring: Codable, Equatable, Sendable {
    nonisolated enum Reason: String, Codable, Equatable, Sendable {
        case stalled
        case batteryBelowThreshold
    }

    let firedAt: Date
    let reason: Reason
    let mode: WatchdogMode
    let sessionStart: Date
    let heldSeconds: TimeInterval
    /// `now − lastMainHeartbeat` at fire time. The measurement F-003 lacked:
    /// a large value means the main actor was genuinely blocked, while ≈0 with
    /// a lapsed deadline means it was alive and the idle timer simply never
    /// fired — two different bugs that are otherwise indistinguishable.
    let mainStallSeconds: TimeInterval
    let batteryPercent: Int?
    let isOnBattery: Bool
    let assertionIDs: [UInt32]
    let releaseStatuses: [Int32]
}

nonisolated struct WatchdogStall: Codable, Equatable, Sendable {
    nonisolated enum Side: String, Codable, Equatable, Sendable {
        case mainActor
        case watchdog
    }

    let observedAt: Date
    let side: Side
    let seconds: TimeInterval
}

nonisolated enum WatchdogEvent: Codable, Equatable, Sendable {
    case fired(WatchdogFiring)
    /// Emitted without any release. A freeze that recovers on its own leaves
    /// no other trace, yet it is the same defect that later freezes for hours.
    case stallObserved(WatchdogStall)
    /// Notify-only. Never releases — an untimed manual session is a deliberate
    /// choice and overriding it would be wrong.
    case untimedOnBatteryNudge(hours: Int)

    /// True for the events that released nothing. Not cosmetic: the bounded
    /// evidence ring evicts on this, because the two classes of record have very
    /// different arrival rates and very different worth. A `.fired` is the
    /// forensics of an actual F-003 — rare, and the only reason the file exists.
    /// The notify-only records are breadcrumbs that can arrive repeatedly within
    /// a single session (any main-actor quiet past `stallThreshold`, re-armable
    /// by every heartbeat), so under plain FIFO they would eventually push the
    /// firing they were meant to give context to out of the ring.
    var isNotifyOnly: Bool {
        switch self {
        case .fired: false
        case .stallObserved, .untimedOnBatteryNudge: true
        }
    }
}
