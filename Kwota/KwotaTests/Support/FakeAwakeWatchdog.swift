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
    /// Drives the mutual-watch tests.
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

    func lastTickAgeSeconds() -> TimeInterval? { stubbedLastTickAge }

    func disarm() -> [SleepAssertion] {
        lock.lock(); defer { lock.unlock() }
        _disarmCount += 1
        let held = _isArmed ? (_armCalls.last?.assertions ?? []) : []
        _isArmed = false
        return disarmReturns ?? held
    }
}
