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
    /// How long `arm()`/`disarm()` will wait for an in-flight `tick()` release
    /// to resolve before giving up and proceeding anyway (see
    /// `waitForInFlightRelease`). A real `IOPMAssertionRelease` call is local
    /// mach IPC and normally resolves in well under a millisecond, so this is
    /// generous slack for a slow-but-healthy release, not a budget anyone
    /// should expect to actually spend — while still being short enough that
    /// a genuinely wedged `powerd` can't freeze whatever main-actor recovery
    /// path called in for anywhere near as long as F-003's multi-hour stalls.
    static let defaultReleaseWaitTimeout: TimeInterval = 3

    /// Instance properties, not constants, purely so tests can drive a real
    /// `DispatchSourceTimer` without waiting out a two-minute grace. Production
    /// always takes the defaults above.
    private let deadlineGrace: TimeInterval
    private let batteryGrace: TimeInterval
    private let releaseWaitTimeout: TimeInterval

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

    /// `NSCondition` rather than `NSLock`: `arm()`/`disarm()` need to wait for
    /// an in-flight `tick()` release to finish (see `releasingEpoch` below)
    /// without polling, and `NSCondition` gives that for free while still
    /// supporting plain `lock()`/`unlock()` everywhere else in this file.
    private let lock = NSCondition()
    private var armed: Armed?
    /// Bumped on every `arm()`/`disarm()`. `tick()` snapshots this alongside
    /// `armed` before doing unlocked IO, then checks it again before writing
    /// its result back — if it changed in between, the session `tick()` was
    /// releasing has already ended or been replaced, and committing stale
    /// results would resurrect or clobber the wrong one.
    private var armEpoch: UInt64 = 0
    /// Set to the epoch of the session `tick()` is currently releasing,
    /// exactly for the unlocked window between its snapshot and commit
    /// passes; nil the rest of the time. `arm()`/`disarm()` wait on this
    /// rather than proceeding, so neither ever calls `releaser()` on an
    /// assertion ID `tick()` is concurrently releasing — the double-release
    /// race a Bool-only lock-scope fix would otherwise still allow.
    private var releasingEpoch: UInt64?
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
        releaseWaitTimeout: TimeInterval = AwakeWatchdog.defaultReleaseWaitTimeout,
        uptime: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        wallClock: @escaping @Sendable () -> Date = Date.init,
        releaser: @escaping @Sendable (SleepAssertion) -> Int32 = { IOKitSleepAssertionHolder.releaseRaw($0) },
        sampler: @escaping @Sendable () -> BatteryReading = PowerSourceSampler.snapshot,
        evidence: any WatchdogEvidenceWriting = NoopWatchdogEvidenceWriter(),
        autoStartTimer: Bool = true
    ) {
        self.deadlineGrace = deadlineGrace
        self.batteryGrace = batteryGrace
        self.releaseWaitTimeout = releaseWaitTimeout
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

    /// Waits for an in-flight `tick()` release of the currently-armed session
    /// to resolve, bounded by `releaseWaitTimeout`. Must be called with `lock`
    /// already held. Returns `true` if the deadline was reached before the
    /// release resolved (i.e. `tick()` — most plausibly `releaser()` itself —
    /// is still stuck), `false` if there was nothing to wait for or the wait
    /// resolved normally.
    ///
    /// Unbounded here would mean a wedged `IOPMAssertionRelease` inside
    /// `tick()` freezes whichever synchronous, main-actor-called method
    /// (`arm()`/`disarm()`) happens to race it — the exact failure class this
    /// type exists to prevent, arriving via its own concurrency fix instead of
    /// via the app's original release paths.
    private func waitForInFlightRelease() -> Bool {
        guard armed != nil, releasingEpoch == armEpoch else { return false }
        let deadline = Date().addingTimeInterval(releaseWaitTimeout)
        while armed != nil && releasingEpoch == armEpoch {
            if !lock.wait(until: deadline) {
                return true
            }
        }
        return false
    }

    func arm(assertions: [SleepAssertion], mode: WatchdogMode, releaseAfter: TimeInterval?) {
        let now = uptime()
        lock.lock()
        // If `tick()` is mid-release for whatever is currently armed, wait for
        // it to finish before taking over. Without this, the stale-cleanup
        // loop below could call `releaser()` on the exact same assertion IDs
        // `tick()` is independently releasing right now — a double release of
        // real IOPMAssertionRelease calls, not just a bookkeeping race.
        if waitForInFlightRelease() {
            // The previous session's release never resolved within our
            // budget — most plausibly a wedged `powerd`. Proceed anyway
            // rather than hang this call (and whatever main-actor path
            // invoked it) indefinitely: released empirically, a duplicate
            // `IOPMAssertionRelease` on an already-released or
            // concurrently-releasing valid ID returns `kIOReturnBadArgument`
            // to whichever caller loses the race, not a crash — so racing the
            // wedged call is the safer failure mode compared to freezing the
            // caller forever.
            AppLog.shared.log(
                "AwakeWatchdog.arm timed out waiting for the previous session's in-flight release; proceeding anyway",
                level: .error
            )
        }
        let stale = armed
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
        armEpoch &+= 1
        batteryBelowSinceUptime = nil
        lock.unlock()

        // IO (log + release) happens unlocked: `stale` is already detached
        // from `armed`, so there is nothing left for another thread to race
        // against here, and a wedged `releaser` must not be able to block a
        // concurrent `disarm()`/`mainHeartbeat()` behind this lock.
        if let stale {
            // Reaching this is a caller lifecycle bug, but overwriting `armed`
            // while it still holds unreleased assertions leaks them to nobody.
            AppLog.shared.log("AwakeWatchdog.arm called while already armed", level: .warn)
            for assertion in stale.assertions { _ = releaser(assertion) }
        }
    }

    func bumpDeadline(releaseAfter: TimeInterval) {
        let now = uptime()
        lock.lock()
        defer { lock.unlock() }
        // Once a firing has been reported, the deadline has already done its
        // job and a straggler assertion may still be pending retry. Letting
        // ordinary main-actor activity (agent replies, keystrokes) push the
        // deadline back out here would silence that retry indefinitely —
        // the exact multi-hour stuck assertion this watchdog exists to catch.
        guard var current = armed, current.deadlineUptime != nil, !current.firingReported else { return }
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
        // If `tick()` is mid-release for the currently armed session, the
        // assertions sitting in `armed` right now are the exact ones its
        // unlocked release loop is already calling `releaser()` on. Racing
        // ahead and handing them back here too would mean two independent
        // `IOPMAssertionRelease` calls for the same ID — wait for that release
        // to finish and land its outcome (success clears `armed`; failure
        // leaves the true straggler) before answering.
        if waitForInFlightRelease() {
            // The in-flight release never resolved within our budget. Hand
            // the assertions back anyway rather than returning empty: if this
            // call returned empty here, the caller believes the session ended
            // cleanly and stops tracking it, and if the wedged release truly
            // never returns, that assertion is now orphaned with no owner at
            // all — the exact F-003 failure this type exists to close.
            // Handing it back risks, at worst, a second concurrent
            // `IOPMAssertionRelease` on the same ID once the wedged call
            // eventually resolves — empirically confirmed to return
            // `kIOReturnBadArgument` to the loser, not a crash — which is a
            // strictly safer outcome than a silent, permanent orphan.
            AppLog.shared.log(
                "AwakeWatchdog.disarm timed out waiting for an in-flight release; handing back assertions that may still be mid-release rather than risk orphaning them",
                level: .error
            )
        }
        // Whatever is still in `armed` is still held by the kernel — either we
        // never fired, or we fired and some releases failed. Either way the
        // caller must release it; dropping it here is how an assertion ends up
        // with no owner at all.
        let stillHeld = armed?.assertions ?? []
        armed = nil
        armEpoch &+= 1
        batteryBelowSinceUptime = nil
        return stillHeld
    }

    // MARK: Tick

    /// Internal so tests drive it directly rather than waiting on a real timer.
    ///
    /// Structured in three passes — snapshot, unlocked IO, commit — so `lock`
    /// is never held across `releaser()`, `sampler()`, or `AppLog` calls. Those
    /// can block on `powerd`/IOKit or on the log's own queue; a main actor that
    /// calls `mainHeartbeat()`/`lastTickAgeSeconds()`/`bumpDeadline()`/
    /// `setBatteryThreshold()` synchronously would otherwise queue up behind
    /// whichever thread is doing that IO, turning the one release path with no
    /// main-thread dependency into a new way to stall the main thread — the
    /// exact failure class this type exists to catch. `arm()`/`disarm()` are
    /// the two calls that *do* need to coordinate with this window (see
    /// `releasingEpoch`), because they touch the very assertions this method
    /// is releasing.
    func tick() {
        let now = uptime()

        // Pass 1: snapshot under lock. No IO here, so this is always fast.
        lock.lock()
        lastTickUptime = now
        guard let current = armed else { lock.unlock(); return }
        let epoch = armEpoch

        // Deadline rule. Battery is evaluated in Task 5; the ordering there
        // puts battery first because it is the rule tied to real-world harm.
        let deadlineLapsed = current.deadlineUptime.map { now > $0 } ?? false
        guard deadlineLapsed else { lock.unlock(); return }

        let assertionsToRelease = current.assertions
        let wasFiringReported = current.firingReported
        let mode = current.mode
        let sessionStart = current.startedAtWall
        let heldSeconds = seconds(now &- current.startedAtUptime)
        let stallSeconds = seconds(now &- current.lastMainHeartbeatUptime)
        // Mark this epoch as "releasing" before giving up the lock, so a
        // concurrent `arm()`/`disarm()` sees it and waits instead of also
        // calling `releaser()` on these same assertions.
        releasingEpoch = epoch
        lock.unlock()

        // Pass 2: unlocked IO. This is the part that can genuinely block —
        // real mach IPC to powerd, IOKit battery queries, log writes — and
        // none of it needs the lock.
        var statuses: [Int32] = []
        var stillHeld: [SleepAssertion] = []
        for assertion in assertionsToRelease {
            let status = releaser(assertion)
            statuses.append(status)
            // A failed release must stay armed and be retried. Clearing it
            // would leave the record, the reconcile and `isActive` all
            // claiming "released" while the kernel still holds it — a
            // silent return to the exact F-003 symptom with nothing left
            // to retry.
            if status != kIOReturnSuccess { stillHeld.append(assertion) }
        }

        var eventToEmit: WatchdogEvent?
        if !wasFiringReported {
            let reading = sampler()
            eventToEmit = .fired(WatchdogFiring(
                firedAt: wallClock(),
                reason: .stalled,
                mode: mode,
                sessionStart: sessionStart,
                heldSeconds: heldSeconds,
                mainStallSeconds: stallSeconds,
                batteryPercent: reading.percent,
                isOnBattery: reading.isOnBattery,
                assertionIDs: assertionsToRelease.map(\.id),
                releaseStatuses: statuses
            ))
        } else {
            AppLog.shared.log(
                "AwakeWatchdog: retrying \(stillHeld.count) failed assertion release(s)",
                level: .warn
            )
        }

        // Pass 3: commit under lock, but only if the session we just acted on
        // is still the one that's armed. `armEpoch` changes on every arm()/
        // disarm(), so a mismatch here means the caller ended or replaced this
        // session while the IO above was in flight — writing `stillHeld` back
        // in that case would resurrect a session that was deliberately ended,
        // or corrupt an unrelated new one. The release calls above already ran
        // for real regardless; only the in-memory bookkeeping is skipped.
        lock.lock()
        if armEpoch == epoch, var latest = armed {
            if stillHeld.isEmpty {
                armed = nil
                batteryBelowSinceUptime = nil
            } else {
                latest.assertions = stillHeld
                if !wasFiringReported { latest.firingReported = true }
                armed = latest
            }
        }
        // Clear the in-flight marker and wake anyone parked in `arm()`/
        // `disarm()`'s wait loop above — the release this epoch was doing is
        // now fully resolved, one way or the other.
        releasingEpoch = nil
        lock.broadcast()
        lock.unlock()

        if let event = eventToEmit {
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
