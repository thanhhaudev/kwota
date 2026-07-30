//
//  AwakeWatchdog.swift
//  Kwota
//
//  Releases Kwota's keep-awake assertion without the main actor.
//
//  Every existing release path — the idle timer, the user-return poll, the
//  battery notification sink, the manual timeout — runs on `@MainActor`, while
//  the IOKit assertion lives in the kernel and outlives any app-side stall.
//  F-003 is what that asymmetry costs: eight hours of assertion, a battery
//  drained to 1%, and a forced Low Power Sleep. This type is the one release
//  path with no main-thread dependency anywhere in it.
//

import Foundation
import Combine

nonisolated protocol AwakeWatchdogging: AnyObject, Sendable {
    /// Takes ownership of `assertions` and starts ticking. `releaseAfter` is
    /// the app's own intended release window — the idle window for auto, the
    /// timeout for manual — and the watchdog adds `deadlineGrace` itself so
    /// that constant is defined in exactly one place. Pass nil for
    /// manual-without-timeout: that session is governed by the battery rule only.
    func arm(assertions: [SleepAssertion], mode: WatchdogMode, releaseAfter: TimeInterval?)

    /// Pushes the deadline out to `releaseAfter + grace` from now. No-op when
    /// not armed, or when the armed session has no deadline rule.
    func bumpDeadline(releaseAfter: TimeInterval)

    /// Config push. Valid whether or not armed.
    func setBatteryThreshold(_ percent: Int?)

    /// Liveness ping from the main actor. Diagnostic only — never a trigger.
    func mainHeartbeat()

    /// Seconds since the last tick, or nil when never ticked. The main actor
    /// reads this to notice a watchdog that has silently stopped.
    func lastTickAgeSeconds() -> TimeInterval?

    /// Hands ownership back and returns exactly the assertions the caller must
    /// now release — empty when the watchdog already released them all.
    ///
    /// An array rather than a Bool on purpose. A Bool must mean either "was
    /// still armed" or "had not fired", and the partial-failure path makes those
    /// diverge: after a firing where some releases failed, the watchdog is still
    /// armed *and* has already fired, and the kernel still holds those
    /// assertions. Either Bool answer loses information, and the losing answer
    /// strands a live assertion with no owner — F-003 all over again.
    func disarm() -> [SleepAssertion]

    /// Everything the watchdog observes. Sent from its own queue; subscribers
    /// hop to the main actor themselves.
    var events: AnyPublisher<WatchdogEvent, Never> { get }
}

nonisolated final class AwakeWatchdog: AwakeWatchdogging, @unchecked Sendable {

    static let defaultDeadlineGrace: TimeInterval = 120
    static let defaultBatteryGrace: TimeInterval = 120
    static let stallThreshold: TimeInterval = 180
    static let watchdogSilentThreshold: TimeInterval = 90
    static let nudgeAfter: TimeInterval = 2 * 3600

    /// Instance properties, not constants, purely so tests can drive a real
    /// `DispatchSourceTimer` without waiting out a two-minute grace. Production
    /// always takes the defaults above.
    private let deadlineGrace: TimeInterval
    private let batteryGrace: TimeInterval

    private struct Armed {
        var assertions: [SleepAssertion]
        var deadlineUptime: UInt64?
        var mode: WatchdogMode
        var startedAtWall: Date
        var startedAtUptime: UInt64
        var lastMainHeartbeatUptime: UInt64
        var stallLatched: Bool
        var nudgeSent: Bool
        /// Set once the firing has been recorded and published, so retries of
        /// a failed `IOPMAssertionRelease` never duplicate either.
        var firingReported: Bool
    }

    private let lock = NSLock()
    private var armed: Armed?
    private var batteryThreshold: Int?
    private var batteryBelowSinceUptime: UInt64?
    private var lastTickUptime: UInt64?

    private let tickInterval: TimeInterval
    private let uptime: @Sendable () -> UInt64
    private let wallClock: @Sendable () -> Date
    private let releaser: @Sendable (SleepAssertion) -> Int32
    private let sampler: @Sendable () -> BatteryReading
    private let evidence: any WatchdogEvidenceWriting
    private let subject = PassthroughSubject<WatchdogEvent, Never>()

    init(
        tickInterval: TimeInterval = 30,
        deadlineGrace: TimeInterval = AwakeWatchdog.defaultDeadlineGrace,
        batteryGrace: TimeInterval = AwakeWatchdog.defaultBatteryGrace,
        uptime: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        wallClock: @escaping @Sendable () -> Date = Date.init,
        releaser: @escaping @Sendable (SleepAssertion) -> Int32 = { IOKitSleepAssertionHolder.releaseRaw($0) },
        sampler: @escaping @Sendable () -> BatteryReading = PowerSourceSampler.snapshot,
        evidence: any WatchdogEvidenceWriting = NoopWatchdogEvidenceWriter(),
        autoStartTimer: Bool = true
    ) {
        self.deadlineGrace = deadlineGrace
        self.batteryGrace = batteryGrace
        self.tickInterval = tickInterval
        self.uptime = uptime
        self.wallClock = wallClock
        self.releaser = releaser
        self.sampler = sampler
        self.evidence = evidence
        // Timer wiring lands in Task 7; `autoStartTimer` is threaded through
        // now so call sites and tests do not change shape later.
        _ = autoStartTimer
    }

    var events: AnyPublisher<WatchdogEvent, Never> { subject.eraseToAnyPublisher() }

    // MARK: Arming

    func arm(assertions: [SleepAssertion], mode: WatchdogMode, releaseAfter: TimeInterval?) {
        let now = uptime()
        lock.lock()
        if let stale = armed {
            // Reaching this is a caller lifecycle bug, but overwriting `armed`
            // while it still holds unreleased assertions leaks them to nobody.
            AppLog.shared.log("AwakeWatchdog.arm called while already armed", level: .warn)
            for assertion in stale.assertions { _ = releaser(assertion) }
        }
        armed = Armed(
            assertions: assertions,
            deadlineUptime: releaseAfter.map { now &+ nanos($0 + deadlineGrace) },
            mode: mode,
            startedAtWall: wallClock(),
            startedAtUptime: now,
            lastMainHeartbeatUptime: now,
            stallLatched: false,
            nudgeSent: false,
            firingReported: false
        )
        batteryBelowSinceUptime = nil
        lock.unlock()
    }

    func bumpDeadline(releaseAfter: TimeInterval) {
        let now = uptime()
        lock.lock()
        defer { lock.unlock() }
        guard var current = armed, current.deadlineUptime != nil else { return }
        current.deadlineUptime = now &+ nanos(releaseAfter + deadlineGrace)
        armed = current
    }

    func setBatteryThreshold(_ percent: Int?) {
        lock.lock()
        batteryThreshold = percent
        if percent == nil { batteryBelowSinceUptime = nil }
        lock.unlock()
    }

    func mainHeartbeat() {
        let now = uptime()
        lock.lock()
        defer { lock.unlock() }
        guard var current = armed else { return }
        current.lastMainHeartbeatUptime = now
        current.stallLatched = false
        armed = current
    }

    func lastTickAgeSeconds() -> TimeInterval? {
        let now = uptime()
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastTickUptime else { return nil }
        return seconds(now &- last)
    }

    func disarm() -> [SleepAssertion] {
        lock.lock()
        defer { lock.unlock() }
        // Whatever is still in `armed` is still held by the kernel — either we
        // never fired, or we fired and some releases failed. Either way the
        // caller must release it; dropping it here is how an assertion ends up
        // with no owner at all.
        let stillHeld = armed?.assertions ?? []
        armed = nil
        batteryBelowSinceUptime = nil
        return stillHeld
    }

    // MARK: Tick

    /// Internal so tests drive it directly rather than waiting on a real timer.
    func tick() {
        let now = uptime()
        var toEmit: [WatchdogEvent] = []

        lock.lock()
        lastTickUptime = now
        guard var current = armed else { lock.unlock(); return }

        // Deadline rule. Battery is evaluated in Task 5; the ordering there
        // puts battery first because it is the rule tied to real-world harm.
        let deadlineLapsed = current.deadlineUptime.map { now > $0 } ?? false

        if deadlineLapsed {
            let stall = seconds(now &- current.lastMainHeartbeatUptime)
            var statuses: [Int32] = []
            var stillHeld: [SleepAssertion] = []
            for assertion in current.assertions {
                let status = releaser(assertion)
                statuses.append(status)
                // A failed release must stay armed and be retried. Clearing it
                // would leave the record, the reconcile and `isActive` all
                // claiming "released" while the kernel still holds it — a
                // silent return to the exact F-003 symptom with nothing left
                // to retry.
                if status != kIOReturnSuccess { stillHeld.append(assertion) }
            }

            if !current.firingReported {
                let reading = sampler()
                toEmit.append(.fired(WatchdogFiring(
                    firedAt: wallClock(),
                    reason: .stalled,
                    mode: current.mode,
                    sessionStart: current.startedAtWall,
                    heldSeconds: seconds(now &- current.startedAtUptime),
                    mainStallSeconds: stall,
                    batteryPercent: reading.percent,
                    isOnBattery: reading.isOnBattery,
                    assertionIDs: current.assertions.map(\.id),
                    releaseStatuses: statuses
                )))
                current.firingReported = true
            } else {
                AppLog.shared.log(
                    "AwakeWatchdog: retrying \(stillHeld.count) failed assertion release(s)",
                    level: .warn
                )
            }

            if stillHeld.isEmpty {
                armed = nil
                batteryBelowSinceUptime = nil
            } else {
                current.assertions = stillHeld
                armed = current
            }
        } else {
            armed = current
        }
        lock.unlock()

        for event in toEmit {
            evidence.append(event)   // disk first: main may never come back
            subject.send(event)
        }
    }

    // MARK: Units

    private func nanos(_ seconds: TimeInterval) -> UInt64 {
        UInt64((seconds * 1_000_000_000).rounded())
    }

    private func seconds(_ nanos: UInt64) -> TimeInterval {
        TimeInterval(nanos) / 1_000_000_000
    }
}
