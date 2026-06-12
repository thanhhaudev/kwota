//
//  UserInputMonitor.swift
//  Kwota
//

import CoreGraphics
import Foundation

/// Seconds since the user last touched any HID input (keyboard, mouse,
/// trackpad). Seam so `AwakeSupervisor` tests can fake user presence
/// instead of reading the real session's idle counter.
protocol UserInputIdleProviding {
    func secondsSinceLastInput() -> TimeInterval
}

/// Live implementation backed by Quartz Event Services. The
/// `.combinedSessionState` source aggregates every input device in the
/// login session, and `kCGAnyInputEventType` (`~0`) folds all event types
/// into one idle counter — the same counter `ioreg`'s `HIDIdleTime`
/// exposes. No privacy permission (Input Monitoring etc.) is required to
/// read it.
struct SystemUserInputMonitor: UserInputIdleProviding {
    func secondsSinceLastInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: UInt32.max)!
        )
    }
}
