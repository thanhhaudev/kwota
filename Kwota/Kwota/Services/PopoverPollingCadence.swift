//
//  PopoverPollingCadence.swift
//  Kwota
//
//  Shared cadence state for pollers that run fast while the menu-bar popover
//  is open and back off while it's closed. Both `UsageRefreshCoordinator`
//  (jittered Timer) and `AntigravityProcessWatcher` (detached sleep loop)
//  own one of these; the scheduling mechanism differs, but the "default to
//  closed at launch, flip on open/close, only reschedule on an actual change"
//  rule lives here once.
//

import Foundation

struct PopoverPollingCadence {
    let openInterval: TimeInterval
    let closedInterval: TimeInterval

    /// The interval the owner's scheduler should currently use. Starts at the
    /// closed interval because the popover is closed at launch.
    private(set) var currentInterval: TimeInterval

    init(openInterval: TimeInterval, closedInterval: TimeInterval) {
        self.openInterval = openInterval
        self.closedInterval = closedInterval
        self.currentInterval = closedInterval
    }

    /// Switch to the fast (open) cadence. Returns `true` if the interval
    /// actually changed, so the owner only reschedules when it must.
    mutating func setOpen() -> Bool { set(openInterval) }

    /// Switch to the slow (closed) cadence. Returns `true` on an actual change.
    mutating func setClosed() -> Bool { set(closedInterval) }

    private mutating func set(_ interval: TimeInterval) -> Bool {
        guard currentInterval != interval else { return false }
        currentInterval = interval
        return true
    }
}
