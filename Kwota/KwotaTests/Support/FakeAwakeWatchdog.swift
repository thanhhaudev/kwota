//
//  FakeAwakeWatchdog.swift
//  KwotaTests
//

import Foundation
import Combine
@testable import Kwota

final class FakeAwakeWatchdog: AwakeWatchdogging, @unchecked Sendable {
    struct ArmCall: Equatable {
        let assertions: [SleepAssertion]
        let mode: WatchdogMode
        let releaseAfter: TimeInterval?
    }

    private let lock = NSLock()
    private var _armCalls: [ArmCall] = []
    private var _bumps: [TimeInterval] = []
    private var _thresholds: [Int?] = []
    private var _heartbeats = 0
    private var _disarmCount = 0
    private var _isArmed = false

    /// What `disarm()` hands back. Default `nil` means "whatever was armed";
    /// set it to `[]` to simulate a clean firing, or to a subset to simulate a
    /// firing where some releases failed.
    var disarmReturns: [SleepAssertion]?
    /// Mirrors `WatchdogDisarm.releaseAlreadyAttempted`. Defaults to false —
    /// "nothing fired, these were never handed to IOKit" — which is what the
    /// plain enable/disable tests model. Set it alongside `disarmReturns` to
    /// model a straggler the watchdog's own release already failed on.
    var disarmReportsAttemptedRelease = false
    /// Drives the mutual-watch tests. Only reported while armed — see
    /// `lastTickAgeSeconds()`.
    var stubbedLastTickAge: TimeInterval?

    let subject = PassthroughSubject<WatchdogEvent, Never>()
    var events: AnyPublisher<WatchdogEvent, Never> { subject.eraseToAnyPublisher() }

    var armCalls: [ArmCall] { lock.lock(); defer { lock.unlock() }; return _armCalls }
    var bumps: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _bumps }
    var thresholds: [Int?] { lock.lock(); defer { lock.unlock() }; return _thresholds }
    var heartbeats: Int { lock.lock(); defer { lock.unlock() }; return _heartbeats }
    var disarmCount: Int { lock.lock(); defer { lock.unlock() }; return _disarmCount }
    var isArmed: Bool { lock.lock(); defer { lock.unlock() }; return _isArmed }

    func arm(assertions: [SleepAssertion], mode: WatchdogMode, releaseAfter: TimeInterval?) {
        lock.lock(); defer { lock.unlock() }
        _armCalls.append(ArmCall(assertions: assertions, mode: mode, releaseAfter: releaseAfter))
        _isArmed = true
    }

    func bumpDeadline(releaseAfter: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _bumps.append(releaseAfter)
    }

    func setBatteryThreshold(_ percent: Int?) {
        lock.lock(); defer { lock.unlock() }
        _thresholds.append(percent)
    }

    func mainHeartbeat() {
        lock.lock(); defer { lock.unlock() }
        _heartbeats += 1
    }

    /// Armed-aware on purpose, mirroring the real `AwakeWatchdog`: an unarmed
    /// watchdog has stopped its own timer and reports no age at all, however
    /// long ago it last ticked. Stubbing the age alone used to be enough here,
    /// and that gap is exactly why a false "watchdog silent" after a clean
    /// firing survived two task-scoped reviews — the fake could not express the
    /// coupling the mutual watch depends on. Tests get an age by arming first
    /// (`arm(...)`, or `CaffeinateManager.enable(...)` which arms for them).
    func lastTickAgeSeconds() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard _isArmed else { return nil }
        return stubbedLastTickAge
    }

    /// Ends the armed session the way a clean firing does inside the real
    /// watchdog: `armed` becomes nil and its timer suspends, so `lastTickUptime`
    /// freezes and the age it would report stops meaning anything.
    ///
    /// Deliberately does *not* publish `.fired` — the whole point of the race
    /// this models is that the watchdog's own state changes at firing time
    /// while the main actor may not see the event until much later, so tests
    /// send on `subject` themselves to control that ordering.
    func simulateCleanFiring() {
        lock.lock(); defer { lock.unlock() }
        _isArmed = false
    }

    func disarm() -> WatchdogDisarm {
        lock.lock(); defer { lock.unlock() }
        _disarmCount += 1
        let held = _isArmed ? (_armCalls.last?.assertions ?? []) : []
        _isArmed = false
        return WatchdogDisarm(
            assertions: disarmReturns ?? held,
            releaseAlreadyAttempted: disarmReportsAttemptedRelease
        )
    }
}
