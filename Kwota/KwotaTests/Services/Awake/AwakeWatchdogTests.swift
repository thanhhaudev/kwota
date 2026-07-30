//
//  AwakeWatchdogTests.swift
//  KwotaTests
//

import XCTest
import Combine
@testable import Kwota

final class AwakeWatchdogTests: XCTestCase {

    /// Collects everything the watchdog releases, and can be told to fail.
    final class SpyReleaser: @unchecked Sendable {
        private let lock = NSLock()
        private var _released: [SleepAssertion] = []
        private var _failIDs: Set<UInt32> = []
        private var gate: DispatchSemaphore?

        var released: [SleepAssertion] {
            lock.lock(); defer { lock.unlock() }; return _released
        }
        func failFor(_ ids: Set<UInt32>) {
            lock.lock(); defer { lock.unlock() }; _failIDs = ids
        }
        func stopFailing() {
            lock.lock(); defer { lock.unlock() }; _failIDs = []
        }
        /// Makes the *next* `release` call block on `gate` before doing
        /// anything else — a stand-in for a wedged `IOPMAssertionRelease`, so
        /// a test can park `tick()` mid-release and prove other watchdog
        /// calls don't queue up behind it.
        func blockNextRelease(on gate: DispatchSemaphore) {
            lock.lock(); defer { lock.unlock() }; self.gate = gate
        }

        /// A *durable* wedge: once set, **every** `release` call parks until
        /// `unwedgeAllReleases()`. `blockNextRelease(on:)` cannot model this —
        /// it clears after one call, so a second, redundant release sails
        /// straight through and a caller that would hang in production against
        /// an unresponsive `powerd` looks perfectly prompt in the test. Mach
        /// IPC to a wedged daemon blocks; it does not fail fast, and it does
        /// not start succeeding just because someone asked again.
        private let wedge = NSCondition()
        private var isWedged = false
        private var _entered = 0

        /// How many `release` calls have been *entered* (as opposed to
        /// completed). The only observable for a call that never returns.
        var enteredCount: Int {
            wedge.lock(); defer { wedge.unlock() }; return _entered
        }
        func wedgeAllReleases() {
            wedge.lock(); isWedged = true; wedge.unlock()
        }
        func unwedgeAllReleases() {
            wedge.lock(); isWedged = false; wedge.broadcast(); wedge.unlock()
        }

        func release(_ a: SleepAssertion) -> Int32 {
            wedge.lock()
            _entered += 1
            while isWedged { wedge.wait() }
            wedge.unlock()

            let parked: DispatchSemaphore? = {
                lock.lock(); defer { lock.unlock() }
                let g = gate
                gate = nil
                return g
            }()
            parked?.wait()
            lock.lock(); defer { lock.unlock() }
            _released.append(a)
            return _failIDs.contains(a.id) ? -1 : 0
        }
    }

    final class SpyEvidence: WatchdogEvidenceWriting, @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [WatchdogEvent] = []
        var events: [WatchdogEvent] {
            lock.lock(); defer { lock.unlock() }; return _events
        }
        func append(_ event: WatchdogEvent) {
            lock.lock(); defer { lock.unlock() }; _events.append(event)
        }
    }

    /// Mutable fake uptime in nanoseconds.
    final class Uptime: @unchecked Sendable {
        private let lock = NSLock()
        private var nanos: UInt64 = 1_000_000_000
        func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return nanos }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            nanos &+= UInt64(seconds * 1_000_000_000)
        }
    }

    private var uptime: Uptime!
    private var releaser: SpyReleaser!
    private var evidence: SpyEvidence!
    private var battery: BatteryReading!
    private var bag: Set<AnyCancellable>!

    override func setUp() {
        uptime = Uptime()
        releaser = SpyReleaser()
        evidence = SpyEvidence()
        battery = BatteryReading(isOnBattery: false, percent: 100)
        bag = []
    }

    private func makeWatchdog(releaseWaitTimeout: TimeInterval = AwakeWatchdog.defaultReleaseWaitTimeout) -> AwakeWatchdog {
        let up = uptime!
        let rel = releaser!
        let batteryBox = { [weak self] in self?.battery ?? BatteryReading(isOnBattery: false, percent: 100) }
        return AwakeWatchdog(
            releaseWaitTimeout: releaseWaitTimeout,
            uptime: { up.now() },
            wallClock: { Date(timeIntervalSince1970: 0) },
            releaser: { rel.release($0) },
            sampler: { batteryBox() },
            evidence: evidence,
            autoStartTimer: false
        )
    }

    private let a1 = SleepAssertion(id: 1, type: .preventIdleSleep)
    private let a2 = SleepAssertion(id: 2, type: .preventDisplaySleep)

    /// Spins until `condition` holds, or `timeout` elapses. Polling rather than
    /// a semaphore because what these tests need to observe is a thread
    /// *entering* a call that never returns — there is nothing on the far side
    /// left to signal completion.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    // MARK: deadline rule

    func test_deadlineNotLapsed_doesNotFire() {
        let wd = makeWatchdog()
        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 300)
        uptime.advance(300)   // grace is +120, so still armed
        wd.tick()
        XCTAssertTrue(releaser.released.isEmpty)
    }

    func test_deadlineLapsed_releasesAndRecords() {
        let wd = makeWatchdog()
        var received: [WatchdogEvent] = []
        wd.events.sink { received.append($0) }.store(in: &bag)

        wd.arm(assertions: [a1, a2], mode: .auto, releaseAfter: 300)
        uptime.advance(421)
        wd.tick()

        XCTAssertEqual(releaser.released.map(\.id), [1, 2])
        guard case .fired(let f)? = received.first else {
            return XCTFail("expected a fired event, got \(received)")
        }
        XCTAssertEqual(f.reason, .stalled)
        XCTAssertEqual(f.assertionIDs, [1, 2])
        XCTAssertEqual(f.releaseStatuses, [0, 0])
        XCTAssertEqual(evidence.events.count, 1, "record must reach disk too")
    }

    func test_bumpDeadline_pushesTheLapse() {
        let wd = makeWatchdog()
        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 300)
        uptime.advance(400)
        wd.bumpDeadline(releaseAfter: 300)
        uptime.advance(100)   // 100 since the bump; deadline is 420
        wd.tick()
        XCTAssertTrue(releaser.released.isEmpty)
    }

    func test_noDeadlineRule_neverFiresOnTime() {
        let wd = makeWatchdog()
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: nil)
        uptime.advance(86_400)
        wd.tick()
        XCTAssertTrue(releaser.released.isEmpty, "untimed manual has no deadline by design")
    }

    func test_bumpDeadline_isIgnoredWhenSessionHasNoDeadlineRule() {
        let wd = makeWatchdog()
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: nil)
        wd.bumpDeadline(releaseAfter: 10)
        uptime.advance(1000)
        wd.tick()
        XCTAssertTrue(releaser.released.isEmpty)
    }

    // MARK: uptime semantics

    func test_systemSleepDoesNotConsumeGrace() {
        let wd = makeWatchdog()
        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 300)
        // Uptime is mach_absolute_time: it does not advance during sleep, so a
        // three-hour sleep contributes nothing here.
        uptime.advance(10)
        wd.tick()
        XCTAssertTrue(releaser.released.isEmpty)
    }

    // MARK: lifecycle

    func test_disarmBeforeFiring_handsTheAssertionsBack() {
        let wd = makeWatchdog()
        wd.arm(assertions: [a1, a2], mode: .auto, releaseAfter: 300)
        XCTAssertEqual(wd.disarm().map(\.id), [1, 2], "caller must release these")
        uptime.advance(10_000)
        wd.tick()
        XCTAssertTrue(releaser.released.isEmpty)
    }

    func test_disarmAfterCleanFiring_handsBackNothing() {
        let wd = makeWatchdog()
        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 300)
        uptime.advance(421)
        wd.tick()
        XCTAssertTrue(wd.disarm().isEmpty, "already released; a second release would be a race")
    }

    func test_secondTickAfterFiring_isIdempotent() {
        let wd = makeWatchdog()
        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 300)
        uptime.advance(421)
        wd.tick()
        wd.tick()
        XCTAssertEqual(releaser.released.count, 1)
        XCTAssertEqual(evidence.events.count, 1)
    }

    func test_constructedAndReleasedWithoutArming_doesNotTrap() {
        // A suspended DispatchSourceTimer deallocated is an immediate trap, and
        // most watchdogs in a test suite are never armed. autoStartTimer:false
        // here; Task 7 covers the real-timer path.
        for _ in 0..<50 { _ = makeWatchdog() }
    }

    // MARK: release failure

    func test_failedReleaseStaysArmedAndRetriesOnNextTick() {
        let wd = makeWatchdog()
        releaser.failFor([1])
        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 300)
        uptime.advance(421)
        wd.tick()
        XCTAssertEqual(releaser.released.count, 1)

        // Still armed, so the next tick tries again — and now succeeds.
        releaser.stopFailing()
        uptime.advance(60)
        wd.tick()
        XCTAssertEqual(releaser.released.count, 2)
        XCTAssertTrue(wd.disarm().isEmpty, "retry succeeded, nothing left to hand back")
    }

    /// The orphan guard. `disarm()` must hand a still-held assertion back rather
    /// than dropping it: after a failed release the watchdog is simultaneously
    /// "already fired" and "still holding", and a Bool return could only report
    /// one of those. Reporting the wrong one leaves a live kernel assertion with
    /// no owner — F-003, reintroduced by the mechanism meant to prevent it.
    func test_disarmAfterFailedRelease_handsTheStragglerBack() {
        let wd = makeWatchdog()
        releaser.failFor([1])
        wd.arm(assertions: [a1, a2], mode: .auto, releaseAfter: 300)
        uptime.advance(421)
        wd.tick()

        XCTAssertEqual(wd.disarm().map(\.id), [1], "a2 released cleanly; a1 did not")
    }

    func test_failedRelease_recordsAndPublishesExactlyOnce() {
        let wd = makeWatchdog()
        var received: [WatchdogEvent] = []
        wd.events.sink { received.append($0) }.store(in: &bag)

        releaser.failFor([1])
        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 300)
        uptime.advance(421)
        wd.tick()
        uptime.advance(60)
        wd.tick()   // retry
        uptime.advance(60)
        wd.tick()   // retry again

        XCTAssertGreaterThan(releaser.released.count, 1, "retries must keep happening")
        XCTAssertEqual(received.filter { if case .fired = $0 { return true } else { return false } }.count, 1)
        XCTAssertEqual(evidence.events.filter { if case .fired = $0 { return true } else { return false } }.count, 1)
    }

    // MARK: lock scope

    /// `tick()`'s release loop must not hold the internal lock while it calls
    /// out to `releaser`/`sampler`/`AppLog`. If it did, a wedged release (a
    /// plausible root cause of the very stall this watchdog exists to catch)
    /// would leave the lock held indefinitely, and every synchronous call the
    /// main actor makes on this type — `mainHeartbeat`, `disarm`, `arm` — would
    /// queue up behind it, turning the one release path with no main-thread
    /// dependency into a brand-new way to freeze the main thread.
    func test_tickReleaseIO_doesNotBlockOtherCallsBehindTheLock() {
        let wd = makeWatchdog()
        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 300)
        uptime.advance(421)

        let gate = DispatchSemaphore(value: 0)
        releaser.blockNextRelease(on: gate)

        let tickFinished = expectation(description: "tick finished")
        DispatchQueue.global().async {
            wd.tick()   // parks inside releaser() on `gate`
            tickFinished.fulfill()
        }

        // Give the background tick a moment to actually reach the blocked
        // release call before we probe the lock from here.
        Thread.sleep(forTimeInterval: 0.2)

        let heartbeatReturned = expectation(description: "mainHeartbeat returned promptly")
        DispatchQueue.global().async {
            wd.mainHeartbeat()
            heartbeatReturned.fulfill()
        }
        // Bounded wait: if tick() held the lock across the parked release,
        // this times out instead of hanging the whole test run.
        wait(for: [heartbeatReturned], timeout: 1.0)

        gate.signal()
        wait(for: [tickFinished], timeout: 2.0)
        XCTAssertEqual(releaser.released.map(\.id), [1])
    }

    // MARK: bumpDeadline after firing

    /// Once a firing has been recorded, `bumpDeadline` must be a no-op even
    /// though the watchdog is technically still "armed" while a straggler
    /// assertion awaits retry. Letting ordinary auto-mode activity keep
    /// pushing the deadline out here would silence that retry forever —
    /// F-003 again, this time via the retry mechanism meant to prevent it.
    func test_bumpDeadlineAfterFiring_doesNotSuppressThePendingRetry() {
        let wd = makeWatchdog()
        releaser.failFor([1])
        wd.arm(assertions: [a1, a2], mode: .auto, releaseAfter: 300)
        uptime.advance(421)
        wd.tick()   // fires; a2 released cleanly, a1 is the straggler
        XCTAssertEqual(releaser.released.map(\.id), [1, 2])

        // Ordinary main-actor activity (an agent reply, in auto mode) tries
        // to push the deadline out, as it would for a session that never fired.
        wd.bumpDeadline(releaseAfter: 300)
        releaser.stopFailing()
        uptime.advance(60)
        wd.tick()   // must still retry — the bump above must have been ignored

        XCTAssertEqual(releaser.released.map(\.id), [1, 2, 1], "retry must not be suppressed by the bump")
        XCTAssertTrue(wd.disarm().isEmpty, "straggler released on retry; nothing left to hand back")
    }

    // MARK: disarm/arm racing an in-flight release

    /// The lock-scope fix above (unlocked IO in `tick()`) opens a second race
    /// on its own: while `tick()`'s release loop is running unlocked, a
    /// concurrent `disarm()` could read the same still-armed assertions and
    /// hand them back to its caller for release — while `tick()` is
    /// independently calling `releaser()` on the identical IDs. That's a real
    /// double `IOPMAssertionRelease`, not just a bookkeeping inconsistency.
    /// `disarm()` must wait for the in-flight release to resolve instead of
    /// racing ahead of it.
    func test_disarmDuringInFlightRelease_waitsInsteadOfDoubleReleasing() {
        let wd = makeWatchdog()
        wd.arm(assertions: [a1, a2], mode: .auto, releaseAfter: 300)
        uptime.advance(421)

        let gate = DispatchSemaphore(value: 0)
        releaser.blockNextRelease(on: gate)   // parks tick() inside releaser(a1)

        let tickFinished = expectation(description: "tick finished")
        DispatchQueue.global().async {
            wd.tick()
            tickFinished.fulfill()
        }
        // Let the background tick reach the parked release call — by this
        // point `releasingEpoch` is already set, since that happens before
        // the lock is released, well ahead of the actual `releaser()` call.
        Thread.sleep(forTimeInterval: 0.2)

        var disarmResult: [SleepAssertion] = []
        let disarmCompleted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            disarmResult = wd.disarm()
            disarmCompleted.signal()
        }

        // If disarm() raced ahead of the in-flight release instead of
        // waiting, it would complete almost immediately here, handing a1/a2
        // back to this thread while tick()'s own loop is still releasing
        // them independently.
        XCTAssertEqual(
            disarmCompleted.wait(timeout: .now() + 0.3), .timedOut,
            "disarm() must wait for the in-flight release rather than racing ahead of it"
        )

        gate.signal()   // let the parked release proceed
        wait(for: [tickFinished], timeout: 2.0)

        // disarm() must resume promptly now that the release it was waiting
        // on has resolved.
        XCTAssertEqual(
            disarmCompleted.wait(timeout: .now() + 1.0), .success,
            "disarm() must resume once the in-flight release completes"
        )

        // Exactly one release() call per assertion — no ID was ever the
        // target of two independent releaser() calls.
        XCTAssertEqual(releaser.released.map(\.id).sorted(), [1, 2])
        XCTAssertTrue(disarmResult.isEmpty, "tick() already released both cleanly; nothing left for disarm() to hand back")
    }

    /// Same race, from `arm()`'s side: a fresh `arm()` call must not run its
    /// stale-cleanup release loop against assertions `tick()` is still
    /// releasing for the session being replaced.
    func test_armDuringInFlightRelease_waitsInsteadOfDoubleReleasing() {
        let wd = makeWatchdog()
        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 300)
        uptime.advance(421)

        let gate = DispatchSemaphore(value: 0)
        releaser.blockNextRelease(on: gate)   // parks tick() inside releaser(a1)

        let tickFinished = expectation(description: "tick finished")
        DispatchQueue.global().async {
            wd.tick()
            tickFinished.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)

        let replacement = a2
        let armCompleted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            wd.arm(assertions: [replacement], mode: .manual, releaseAfter: nil)
            armCompleted.signal()
        }

        XCTAssertEqual(
            armCompleted.wait(timeout: .now() + 0.3), .timedOut,
            "arm() must wait for the in-flight release of the session it is replacing"
        )

        gate.signal()
        wait(for: [tickFinished], timeout: 2.0)

        XCTAssertEqual(
            armCompleted.wait(timeout: .now() + 1.0), .success,
            "arm() must resume once the in-flight release completes"
        )

        // a1 was released exactly once (by tick()), never by arm()'s
        // stale-cleanup loop.
        XCTAssertEqual(releaser.released.map(\.id), [1])
    }

    // MARK: bounded wait timeout fallback

    /// If the in-flight release genuinely never resolves — a truly wedged
    /// `powerd`, not just a slow one — `disarm()` must not wait forever: that
    /// would freeze whatever main-actor recovery path called it, the exact
    /// failure class this type exists to prevent. Inject a short
    /// `releaseWaitTimeout` and deliberately never signal the gate, so the
    /// wait genuinely expires and the documented fallback (hand the
    /// assertion back anyway, favoring "maybe a harmless duplicate release"
    /// over "silently orphaned forever") runs for real.
    func test_disarmTimesOutWhenReleaseNeverResolves_handsAssertionBackAnyway() {
        let wd = makeWatchdog(releaseWaitTimeout: 0.2)
        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 300)
        uptime.advance(421)

        let gate = DispatchSemaphore(value: 0)   // deliberately never signaled
        releaser.blockNextRelease(on: gate)

        DispatchQueue.global().async {
            wd.tick()   // parks inside releaser() and never returns
        }
        Thread.sleep(forTimeInterval: 0.1)   // let tick() reach the parked release

        var result: [SleepAssertion] = []
        let disarmCompleted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result = wd.disarm()
            disarmCompleted.signal()
        }

        // Must give up and return within a bounded time even though the
        // release it was waiting on never resolves — proving this is the
        // timeout path, not a lucky fast wait.
        XCTAssertEqual(
            disarmCompleted.wait(timeout: .now() + 1.5), .success,
            "disarm() must time out rather than wait forever for a release that never resolves"
        )
        XCTAssertEqual(result.map(\.id), [1], "must hand the still in-flight assertion back rather than silently drop it")

        gate.signal()   // let the permanently parked tick() finish, so nothing dangles past this test
    }

    /// Same fallback, from `arm()`'s side: a stale session whose release never
    /// resolves must not block a fresh `arm()` forever either. The documented
    /// tradeoff is that `arm()` proceeds anyway, accepting that its
    /// stale-cleanup loop may call `releaser()` a second time on an assertion
    /// the old `tick()` is still (fruitlessly) working on — empirically just
    /// a duplicate error return, not a crash.
    func test_armTimesOutWhenPreviousReleaseNeverResolves_proceedsAnyway() {
        let wd = makeWatchdog(releaseWaitTimeout: 0.2)
        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 300)
        uptime.advance(421)

        let gate = DispatchSemaphore(value: 0)   // deliberately never signaled
        releaser.blockNextRelease(on: gate)

        DispatchQueue.global().async {
            wd.tick()   // parks inside releaser() and never returns
        }
        Thread.sleep(forTimeInterval: 0.1)

        let replacement = a2
        let armCompleted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            wd.arm(assertions: [replacement], mode: .manual, releaseAfter: nil)
            armCompleted.signal()
        }

        XCTAssertEqual(
            armCompleted.wait(timeout: .now() + 1.5), .success,
            "arm() must time out and proceed rather than wait forever for the previous session's release"
        )

        // The new session must actually be the one in effect afterward.
        XCTAssertEqual(wd.disarm().map(\.id), [2], "the fresh session must have taken over despite the stale one's stuck release")

        gate.signal()   // let the permanently parked tick() finish, so nothing dangles past this test
    }

    // MARK: stale cleanup must not re-enter the wedge on the caller's thread

    /// The timeout above only bounds the *wait*. Right after it expires, `arm()`
    /// still has to deal with the stale session's assertions — and the premise
    /// for the wait expiring at all is that the release mechanism is
    /// unresponsive, so a fresh `releaser()` call from `arm()` blocks on mach
    /// IPC just like the one it gave up waiting for. Run on the calling thread,
    /// that hands the unbounded hang straight back one statement later, now
    /// disguised as fixed.
    ///
    /// `wedgeAllReleases()` is load-bearing here: with the one-shot
    /// `blockNextRelease(on:)` gate the other timeout tests use, `arm()`'s
    /// redundant release returns instantly and this test passes against code
    /// that would freeze the main thread in production.
    func test_armAfterTimeout_doesNotBlockOnStaleCleanupWhenEveryReleaseIsWedged() {
        let wd = makeWatchdog(releaseWaitTimeout: 0.2)
        releaser.wedgeAllReleases()   // durable: the mechanism itself is unresponsive

        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 300)
        uptime.advance(421)

        DispatchQueue.global().async { wd.tick() }   // parks inside releaser(a1), forever
        XCTAssertTrue(
            waitUntil(1.0) { self.releaser.enteredCount >= 1 },
            "tick() must actually be inside the wedged release before arm() races it"
        )

        let replacement = a2
        let armCompleted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            wd.arm(assertions: [replacement], mode: .manual, releaseAfter: nil)
            armCompleted.signal()
        }

        // 0.2s of bounded wait plus a dispatch. Anything approaching this bound
        // means arm() is sitting in a release call on its own thread.
        XCTAssertEqual(
            armCompleted.wait(timeout: .now() + 1.5), .success,
            "arm() must stay bounded by releaseWaitTimeout even when its own stale-cleanup release is wedged too"
        )

        // Bounded, but not by skipping the work: the stale assertion's release
        // is still attempted, just off the caller's thread.
        XCTAssertTrue(
            waitUntil(1.0) { self.releaser.enteredCount >= 2 },
            "the stale assertion must still be released, on a background thread"
        )
        XCTAssertEqual(
            wd.disarm().map(\.id), [2],
            "the fresh session must be the one in effect despite the stale one's stuck release"
        )

        releaser.unwedgeAllReleases()   // let both parked threads unwind
    }

    /// The same hazard with no in-flight release at all, so the bounded wait
    /// never even engages and the stale-cleanup release is the only unbounded
    /// thing left. This is the general invariant: `arm()` never blocks on
    /// `releaser()`, whatever else is going on.
    func test_armStaleCleanupNeverBlocksTheCaller_withNoReleaseInFlight() {
        let wd = makeWatchdog(releaseWaitTimeout: 0.2)
        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 300)

        // No tick() running, so there is nothing to wait for — waitForInFlight
        // Release() returns immediately and contributes no delay at all.
        releaser.wedgeAllReleases()

        let replacement = a2
        let armCompleted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            wd.arm(assertions: [replacement], mode: .manual, releaseAfter: nil)
            armCompleted.signal()
        }

        XCTAssertEqual(
            armCompleted.wait(timeout: .now() + 1.0), .success,
            "arm() must not run the stale session's release on the calling thread"
        )
        XCTAssertTrue(
            waitUntil(1.0) { self.releaser.enteredCount >= 1 },
            "the stale assertion must still be released, on a background thread"
        )
        XCTAssertEqual(wd.disarm().map(\.id), [2])

        releaser.unwedgeAllReleases()
    }

    // MARK: battery rule

    func test_belowThresholdWithinGrace_doesNotFire() {
        let wd = makeWatchdog()
        wd.setBatteryThreshold(20)
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: nil)
        battery = BatteryReading(isOnBattery: true, percent: 15)

        uptime.advance(30); wd.tick()
        uptime.advance(30); wd.tick()   // 60s below, grace is 120

        XCTAssertTrue(releaser.released.isEmpty, "main gets two minutes to stop gracefully first")
    }

    func test_belowThresholdPastGrace_fires() {
        let wd = makeWatchdog()
        var received: [WatchdogEvent] = []
        wd.events.sink { received.append($0) }.store(in: &bag)

        wd.setBatteryThreshold(20)
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: nil)
        battery = BatteryReading(isOnBattery: true, percent: 15)

        uptime.advance(30); wd.tick()
        uptime.advance(130); wd.tick()

        XCTAssertEqual(releaser.released.map(\.id), [1])
        guard case .fired(let f)? = received.first else {
            return XCTFail("expected fired, got \(received)")
        }
        XCTAssertEqual(f.reason, .batteryBelowThreshold)
        XCTAssertEqual(f.batteryPercent, 15)
        XCTAssertTrue(f.isOnBattery)
    }

    func test_recoveringMidGraceResetsTheClock() {
        let wd = makeWatchdog()
        wd.setBatteryThreshold(20)
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: nil)

        battery = BatteryReading(isOnBattery: true, percent: 15)
        uptime.advance(30); wd.tick()
        battery = BatteryReading(isOnBattery: true, percent: 25)
        uptime.advance(30); wd.tick()
        battery = BatteryReading(isOnBattery: true, percent: 15)
        uptime.advance(100); wd.tick()

        XCTAssertTrue(releaser.released.isEmpty, "grace restarts after a recovery")
    }

    func test_thresholdOff_neverFiresOnBattery() {
        let wd = makeWatchdog()
        wd.setBatteryThreshold(nil)
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: nil)
        battery = BatteryReading(isOnBattery: true, percent: 1)

        uptime.advance(30); wd.tick()
        uptime.advance(600); wd.tick()

        XCTAssertTrue(releaser.released.isEmpty)
    }

    func test_onACPowerNeverFires_evenBelowThreshold() {
        let wd = makeWatchdog()
        wd.setBatteryThreshold(20)
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: nil)
        battery = BatteryReading(isOnBattery: false, percent: 5)

        uptime.advance(30); wd.tick()
        uptime.advance(600); wd.tick()

        XCTAssertTrue(releaser.released.isEmpty, "plugged in means nothing to protect")
    }

    func test_desktopWithNoBattery_neverFires() {
        let wd = makeWatchdog()
        wd.setBatteryThreshold(20)
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: nil)
        battery = BatteryReading(isOnBattery: false, percent: nil)

        uptime.advance(600); wd.tick()

        XCTAssertTrue(releaser.released.isEmpty)
    }

    func test_bothRulesTrip_reasonIsBattery() {
        let wd = makeWatchdog()
        var received: [WatchdogEvent] = []
        wd.events.sink { received.append($0) }.store(in: &bag)

        wd.setBatteryThreshold(20)
        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 300)
        battery = BatteryReading(isOnBattery: true, percent: 15)

        uptime.advance(30); wd.tick()      // starts the battery grace
        uptime.advance(500); wd.tick()     // both deadline and battery grace lapsed

        guard case .fired(let f)? = received.first else {
            return XCTFail("expected fired, got \(received)")
        }
        XCTAssertEqual(f.reason, .batteryBelowThreshold,
                       "battery is the more actionable message for the user")
    }

    // MARK: battery firing + failed release must still retry

    /// The deadline rule's condition is monotonic, so a failed release under it
    /// is retried by every later tick for free — that is what
    /// `test_failedReleaseStaysArmedAndRetriesOnNextTick` covers. The battery
    /// rule's condition is not monotonic: it un-trips the moment the user plugs
    /// in, which is the single most likely thing to happen right after a
    /// low-battery release fires. On an untimed manual session there is no
    /// deadline to fall back on, so if the firing rule's own condition is what
    /// gates the retry, the straggler is abandoned with the kernel still holding
    /// it and nothing left to retry — F-003, reached through the rule added to
    /// prevent it.
    func test_batteryFiringWithFailedRelease_stillRetriesAfterThePowerIsPluggedIn() {
        let wd = makeWatchdog()
        releaser.failFor([1])
        wd.setBatteryThreshold(20)
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: nil)   // battery rule only
        battery = BatteryReading(isOnBattery: true, percent: 15)

        uptime.advance(30); wd.tick()    // starts the grace
        uptime.advance(130); wd.tick()   // fires; the release fails, so a1 stays armed
        XCTAssertEqual(releaser.released.map(\.id), [1])

        // The user plugs in: the battery rule stops holding entirely.
        battery = BatteryReading(isOnBattery: false, percent: 40)
        releaser.stopFailing()
        uptime.advance(30); wd.tick()

        XCTAssertEqual(releaser.released.map(\.id), [1, 1],
                       "the straggler must still be retried once the battery recovers")
        XCTAssertTrue(wd.disarm().isEmpty, "the retry succeeded; nothing left to hand back")
        XCTAssertEqual(evidence.events.count, 1, "a retry must not record a second firing")
    }

    /// Same abandonment, via the other door: turning the threshold off makes
    /// Pass 1 itself bail before the retry, since an untimed manual session with
    /// no threshold has no rule left to evaluate at all. The pending retry must
    /// survive a config change it has nothing to do with.
    func test_batteryFiringWithFailedRelease_stillRetriesAfterTheThresholdIsCleared() {
        let wd = makeWatchdog()
        releaser.failFor([1])
        wd.setBatteryThreshold(20)
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: nil)
        battery = BatteryReading(isOnBattery: true, percent: 15)

        uptime.advance(30); wd.tick()
        uptime.advance(130); wd.tick()   // fires; release fails
        XCTAssertEqual(releaser.released.map(\.id), [1])

        wd.setBatteryThreshold(nil)
        releaser.stopFailing()
        uptime.advance(30); wd.tick()

        XCTAssertEqual(releaser.released.map(\.id), [1, 1],
                       "the straggler must still be retried once the threshold is off")
        XCTAssertTrue(wd.disarm().isEmpty, "the retry succeeded; nothing left to hand back")
    }

    // MARK: stall observation

    private func stalls(in events: [WatchdogEvent]) -> [WatchdogStall] {
        events.compactMap { if case .stallObserved(let s) = $0 { return s } else { return nil } }
    }

    func test_shortStall_recordsNothing() {
        let wd = makeWatchdog()
        var received: [WatchdogEvent] = []
        wd.events.sink { received.append($0) }.store(in: &bag)

        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 3600)
        uptime.advance(100)   // under the 180s threshold
        wd.tick()

        XCTAssertTrue(stalls(in: received).isEmpty)
    }

    func test_longStall_recordsOncePerEpisode() {
        let wd = makeWatchdog()
        var received: [WatchdogEvent] = []
        wd.events.sink { received.append($0) }.store(in: &bag)

        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 3600)
        uptime.advance(200); wd.tick()
        uptime.advance(30);  wd.tick()
        uptime.advance(30);  wd.tick()

        XCTAssertEqual(stalls(in: received).count, 1, "latched: one record per episode")
        XCTAssertEqual(stalls(in: received).first?.side, .mainActor)
    }

    func test_heartbeatResumingClearsTheLatch() {
        let wd = makeWatchdog()
        var received: [WatchdogEvent] = []
        wd.events.sink { received.append($0) }.store(in: &bag)

        wd.arm(assertions: [a1], mode: .auto, releaseAfter: 3600)
        uptime.advance(200); wd.tick()
        wd.mainHeartbeat()
        uptime.advance(200); wd.tick()

        XCTAssertEqual(stalls(in: received).count, 2, "a second episode is a second record")
    }

    // MARK: untimed-on-battery nudge

    private func nudges(in events: [WatchdogEvent]) -> [Int] {
        events.compactMap { if case .untimedOnBatteryNudge(let h) = $0 { return h } else { return nil } }
    }

    func test_untimedManualOnBattery_nudgesOnceAtTwoHours() {
        let wd = makeWatchdog()
        var received: [WatchdogEvent] = []
        wd.events.sink { received.append($0) }.store(in: &bag)

        wd.setBatteryThreshold(nil)
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: nil)
        battery = BatteryReading(isOnBattery: true, percent: 80)

        uptime.advance(7300); wd.tick()
        uptime.advance(60);   wd.tick()

        XCTAssertEqual(nudges(in: received), [2])
        XCTAssertTrue(releaser.released.isEmpty, "a nudge must never release")
    }

    func test_noNudgeOnACPower() {
        let wd = makeWatchdog()
        var received: [WatchdogEvent] = []
        wd.events.sink { received.append($0) }.store(in: &bag)

        wd.setBatteryThreshold(nil)
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: nil)
        battery = BatteryReading(isOnBattery: false, percent: 80)

        uptime.advance(7300); wd.tick()

        XCTAssertTrue(nudges(in: received).isEmpty)
    }

    func test_noNudgeWhenABatteryThresholdIsConfigured() {
        let wd = makeWatchdog()
        var received: [WatchdogEvent] = []
        wd.events.sink { received.append($0) }.store(in: &bag)

        wd.setBatteryThreshold(20)
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: nil)
        battery = BatteryReading(isOnBattery: true, percent: 80)

        uptime.advance(7300); wd.tick()

        XCTAssertTrue(nudges(in: received).isEmpty, "defaults protect the user already")
    }

    /// `hours` is the elapsed session length, not the two-hour trigger restated.
    /// The nudge waits for the machine to actually be on battery, so a session
    /// that runs plugged in for most of the day and is then unplugged nudges on
    /// the next tick — and telling that user "2 hours" would be visibly false.
    func test_nudgeReportsActualElapsedHoursNotTheThreshold() {
        let wd = makeWatchdog()
        var received: [WatchdogEvent] = []
        wd.events.sink { received.append($0) }.store(in: &bag)

        wd.setBatteryThreshold(nil)
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: nil)

        battery = BatteryReading(isOnBattery: false, percent: 100)
        uptime.advance(6 * 3600); wd.tick()   // six hours, but plugged in
        XCTAssertTrue(nudges(in: received).isEmpty, "AC power is nothing to warn about")

        battery = BatteryReading(isOnBattery: true, percent: 90)
        uptime.advance(60); wd.tick()

        XCTAssertEqual(nudges(in: received), [6], "six hours held awake, not the two-hour trigger")
    }

    func test_noNudgeWhenADeadlineRuleExists() {
        let wd = makeWatchdog()
        var received: [WatchdogEvent] = []
        wd.events.sink { received.append($0) }.store(in: &bag)

        wd.setBatteryThreshold(nil)
        wd.arm(assertions: [a1], mode: .manual, releaseAfter: 8 * 3600)
        battery = BatteryReading(isOnBattery: true, percent: 80)

        uptime.advance(7300); wd.tick()

        XCTAssertTrue(nudges(in: received).isEmpty)
    }
}
