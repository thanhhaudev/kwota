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
        func release(_ a: SleepAssertion) -> Int32 {
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

    private func makeWatchdog() -> AwakeWatchdog {
        let up = uptime!
        let rel = releaser!
        let batteryBox = { [weak self] in self?.battery ?? BatteryReading(isOnBattery: false, percent: 100) }
        return AwakeWatchdog(
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
}
