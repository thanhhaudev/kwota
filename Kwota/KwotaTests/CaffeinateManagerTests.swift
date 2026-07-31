//
//  CaffeinateManagerTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class CaffeinateManagerTests: XCTestCase {

    // MARK: - Helpers

    /// All-flags-on options for default-path tests.
    private func allFlagsOptions(timeoutSeconds: Int? = nil) -> CaffeinateOptions {
        CaffeinateOptions(
            preventDisplaySleep: true,
            preventIdleSleep: true,
            preventSystemSleep: true,
            declareUserActivity: true,
            timeoutSeconds: timeoutSeconds
        )
    }

    // MARK: - Tests

    func testStartsDisabled() {
        let manager = CaffeinateManager(holder: MockSleepAssertionHolder())
        XCTAssertFalse(manager.isActive)
        XCTAssertNil(manager.currentOptions)
        XCTAssertNil(manager.startedAt)
    }

    func testEnableAcquiresOneAssertionPerFlag() throws {
        let mock = MockSleepAssertionHolder()
        let manager = CaffeinateManager(holder: mock)

        try manager.enable(options: allFlagsOptions())

        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(
            mock.acquired.map(\.type),
            [.preventDisplaySleep, .preventIdleSleep, .preventSystemSleep]
        )
        XCTAssertEqual(mock.declareUserActivityCount, 1)
        XCTAssertNotNil(manager.startedAt)
    }

    func testEnableSkipsDisabledFlags() throws {
        let mock = MockSleepAssertionHolder()
        let manager = CaffeinateManager(holder: mock)
        let opts = CaffeinateOptions(
            preventDisplaySleep: true,
            preventIdleSleep: false,
            preventSystemSleep: false,
            declareUserActivity: false,
            timeoutSeconds: nil
        )

        try manager.enable(options: opts)

        XCTAssertEqual(mock.acquired.map(\.type), [.preventDisplaySleep])
        XCTAssertEqual(mock.declareUserActivityCount, 0)
    }

    func testEnableIsIdempotent() throws {
        let mock = MockSleepAssertionHolder()
        let manager = CaffeinateManager(holder: mock)

        try manager.enable(options: allFlagsOptions())
        try manager.enable(options: allFlagsOptions()) // second call ignored

        XCTAssertEqual(mock.acquired.count, 3)
    }

    func testDisableReleasesAllAcquiredAssertions() throws {
        let mock = MockSleepAssertionHolder()
        let manager = CaffeinateManager(holder: mock)

        try manager.enable(options: allFlagsOptions())
        manager.disable()

        XCTAssertFalse(manager.isActive)
        XCTAssertNil(manager.currentOptions)
        XCTAssertNil(manager.startedAt)
        XCTAssertEqual(mock.released.count, mock.acquired.count)
        XCTAssertEqual(Set(mock.released.map(\.id)), Set(mock.acquired.indices.map { UInt32($0 + 1) }))
    }

    /// The critical invariant: if any acquire throws partway through, every
    /// already-acquired assertion must be released before the error propagates.
    func testEnableRollsBackPartialAcquireOnError() {
        let mock = MockSleepAssertionHolder()
        let manager = CaffeinateManager(holder: mock)
        // First acquire (display) succeeds, second (idle) throws.
        struct Boom: Error {}
        // We need to allow the first acquire and fail the second. Schedule the
        // error to fire just before the second call by setting it *after* the
        // first acquire — but we cannot run code between manager-driven calls.
        // Instead, use a wrapper that fails on the Nth call.
        let countingMock = CountingFailingHolder(failOnNthAcquire: 2, error: Boom())
        let countingManager = CaffeinateManager(holder: countingMock)

        XCTAssertThrowsError(try countingManager.enable(options: allFlagsOptions())) { error in
            XCTAssertTrue(error is Boom)
        }
        XCTAssertFalse(countingManager.isActive)
        XCTAssertNil(countingManager.currentOptions)
        // One acquire succeeded, one rollback release.
        XCTAssertEqual(countingMock.acquired.count, 1)
        XCTAssertEqual(countingMock.released.count, 1)
        XCTAssertEqual(countingMock.released.first?.type, .preventDisplaySleep)

        _ = mock // silence unused warning if Swift complains
    }

    func testToggleFlipsState() throws {
        let manager = CaffeinateManager(holder: MockSleepAssertionHolder())
        try manager.toggle()
        XCTAssertTrue(manager.isActive)
        try manager.toggle()
        XCTAssertFalse(manager.isActive)
    }

    // MARK: - App Nap suppression

    // The fix for the 7h-stuck-awake bug: while caffeinated, suppress App Nap so
    // the in-process release timers (idle timer / manual timeout) keep firing
    // instead of being frozen while the user is away.
    func testEnableSuppressesAppNap() throws {
        let nap = MockAppNapSuppressor()
        let manager = CaffeinateManager(holder: MockSleepAssertionHolder(), appNap: nap)

        try manager.enable(options: allFlagsOptions())

        XCTAssertEqual(nap.beginCount, 1)
        XCTAssertEqual(nap.liveSuppressions, 1, "App Nap must be suppressed while active")
    }

    func testDisableEndsAppNapSuppression() throws {
        let nap = MockAppNapSuppressor()
        let manager = CaffeinateManager(holder: MockSleepAssertionHolder(), appNap: nap)

        try manager.enable(options: allFlagsOptions())
        manager.disable()

        XCTAssertEqual(nap.endCount, 1)
        XCTAssertEqual(nap.liveSuppressions, 0, "App Nap suppression must be released on disable")
    }

    func testEnableDisableCyclesKeepAppNapBalanced() throws {
        let nap = MockAppNapSuppressor()
        let manager = CaffeinateManager(holder: MockSleepAssertionHolder(), appNap: nap)

        for _ in 0..<3 {
            try manager.enable(options: allFlagsOptions())
            manager.disable()
        }

        XCTAssertEqual(nap.beginCount, 3)
        XCTAssertEqual(nap.endCount, 3)
        XCTAssertEqual(nap.liveSuppressions, 0)
    }

    // A failed acquire throws before we reach the suppression call, so no token
    // is begun (and thus none leaks).
    func testFailedAcquireDoesNotSuppressAppNap() {
        let nap = MockAppNapSuppressor()
        let holder = CountingFailingHolder(failOnNthAcquire: 1, error: NSError(domain: "t", code: 1))
        let manager = CaffeinateManager(holder: holder, appNap: nap)

        XCTAssertThrowsError(try manager.enable(options: allFlagsOptions()))
        XCTAssertEqual(nap.beginCount, 0, "no App Nap token when acquisition fails")
        XCTAssertEqual(nap.liveSuppressions, 0)
    }

    func testTimeoutAutoDisables() async throws {
        let mock = MockSleepAssertionHolder()
        let manager = CaffeinateManager(holder: mock)

        // 200ms timeout — short enough for the test to wait, long enough to
        // be robust to scheduling jitter.
        try manager.enable(options: allFlagsOptions(timeoutSeconds: 0))
        // timeoutSeconds = 0 is the "no timeout" sentinel; sanity-check:
        XCTAssertTrue(manager.isActive)
        manager.disable()
        XCTAssertFalse(manager.isActive)

        // Now a real (positive) timeout. Wait slightly longer than the
        // timeout, then assert auto-release.
        try manager.enable(options: CaffeinateOptions(
            preventDisplaySleep: true,
            preventIdleSleep: false,
            preventSystemSleep: false,
            declareUserActivity: false,
            timeoutSeconds: 1
        ))
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertFalse(manager.isActive, "manager should auto-disable after timeout")
        XCTAssertEqual(mock.released.count, mock.acquired.count)
    }

    // MARK: watchdog handoff

    func testEnableArmsTheWatchdogWithTheAssertions() throws {
        let mock = MockSleepAssertionHolder()
        let wd = FakeAwakeWatchdog()
        let manager = CaffeinateManager(holder: mock, watchdog: wd)

        try manager.enable(options: allFlagsOptions(), mode: .auto, releaseAfter: 300)

        XCTAssertEqual(wd.armCalls.count, 1)
        XCTAssertEqual(wd.armCalls.first?.mode, .auto)
        XCTAssertEqual(wd.armCalls.first?.releaseAfter, 300)
        XCTAssertEqual(wd.armCalls.first?.assertions.count, 3)
    }

    /// A timed manual session has both a timeout and a releaseAfter, so any
    /// inference inside the manager would mislabel it `.auto` and write the
    /// wrong mode into the evidence file.
    func testTimedManualSessionIsArmedAsManual() throws {
        let mock = MockSleepAssertionHolder()
        let wd = FakeAwakeWatchdog()
        let manager = CaffeinateManager(holder: mock, watchdog: wd)

        try manager.enable(options: allFlagsOptions(timeoutSeconds: 7200),
                           mode: .manual, releaseAfter: 7200)

        XCTAssertEqual(wd.armCalls.first?.mode, .manual)
    }

    func testDisableReleasesExactlyWhatDisarmHandsBack() throws {
        let mock = MockSleepAssertionHolder()
        let wd = FakeAwakeWatchdog()
        let manager = CaffeinateManager(holder: mock, watchdog: wd)

        try manager.enable(options: allFlagsOptions())
        manager.disable()

        XCTAssertEqual(wd.disarmCount, 1)
        XCTAssertEqual(mock.released.count, 3, "nothing fired, so all three come back to us")
    }

    func testDisableSkipsReleaseAfterACleanFiring() throws {
        let mock = MockSleepAssertionHolder()
        let wd = FakeAwakeWatchdog()
        let manager = CaffeinateManager(holder: mock, watchdog: wd)

        try manager.enable(options: allFlagsOptions())
        wd.disarmReturns = []           // watchdog released them all
        manager.disable()

        XCTAssertTrue(mock.released.isEmpty, "double-release would be a race, not a safety net")
    }

    /// The orphan guard at the manager level: a straggler the watchdog could not
    /// release must be released here, not silently dropped.
    func testDisableReleasesStragglersAfterAFailedWatchdogRelease() throws {
        let mock = MockSleepAssertionHolder()
        let wd = FakeAwakeWatchdog()
        let recorder = StrandedReleaseRecorder()
        let manager = CaffeinateManager(
            holder: mock, watchdog: wd, strandedReleaser: { recorder.record($0) }
        )

        try manager.enable(options: allFlagsOptions())
        let straggler = wd.armCalls.first!.assertions[1]
        wd.disarmReturns = [straggler]
        wd.disarmReportsAttemptedRelease = true
        manager.disable()

        XCTAssertTrue(
            recorder.waitForRelease(of: straggler, timeout: 2.0),
            "a straggler must still be released — dropping it is how an assertion ends up with no owner"
        )
    }

    /// The straggler is back here *because* releasing it already failed once
    /// inside the watchdog, and `disarm()` has just given up ownership of it —
    /// nothing retries after this. Calling the same unresponsive mechanism
    /// synchronously, from the main actor, with no timeout and no backup, is
    /// F-003 arriving through the recovery path. `disable()` must hand it to a
    /// background queue and return.
    func testDisableDoesNotBlockTheMainActorOnAWedgedStragglerRelease() throws {
        let mock = MockSleepAssertionHolder()
        let wd = FakeAwakeWatchdog()
        let recorder = StrandedReleaseRecorder()
        // Models a wedged IOPMAssertionRelease: mach IPC to a daemon that never
        // answers blocks, it does not fail fast.
        let wedge = DispatchSemaphore(value: 0)
        let manager = CaffeinateManager(
            holder: mock,
            watchdog: wd,
            strandedReleaser: { assertion in
                wedge.wait()
                return recorder.record(assertion)
            }
        )

        try manager.enable(options: allFlagsOptions())
        let straggler = wd.armCalls.first!.assertions[1]
        wd.disarmReturns = [straggler]
        wd.disarmReportsAttemptedRelease = true

        let started = Date()
        manager.disable()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed, 1.0,
            "disable() must not wait on a release that may never answer"
        )
        XCTAssertTrue(
            mock.released.isEmpty,
            "a straggler must not be retried through the main-actor holder — that is the call that can wedge"
        )
        XCTAssertFalse(manager.isActive, "session state is cleared regardless of the release outcome")

        // Unwedge and confirm the release really was in flight, not skipped.
        wedge.signal()
        XCTAssertTrue(recorder.waitForRelease(of: straggler, timeout: 2.0))
    }

    /// The other half of the same rule: an ordinary session (nothing fired)
    /// keeps releasing through the holder, synchronously, on the main actor.
    /// That path has always been fast and is what every other test here — and
    /// `deinit` — observes immediately after the call returns.
    func testDisableReleasesAnUntouchedSessionThroughTheHolderSynchronously() throws {
        let mock = MockSleepAssertionHolder()
        let wd = FakeAwakeWatchdog()
        let recorder = StrandedReleaseRecorder()
        let manager = CaffeinateManager(
            holder: mock, watchdog: wd, strandedReleaser: { recorder.record($0) }
        )

        try manager.enable(options: allFlagsOptions())
        manager.disable()

        XCTAssertEqual(mock.released.count, 3, "nothing fired, so the ordinary path releases all three")
        XCTAssertTrue(recorder.released.isEmpty, "the off-main path is for stragglers only")
    }

    func testAdoptWatchdogReleaseClearsStateWithoutReleasing() throws {
        let mock = MockSleepAssertionHolder()
        let wd = FakeAwakeWatchdog()
        let manager = CaffeinateManager(holder: mock, watchdog: wd)

        try manager.enable(options: allFlagsOptions())
        manager.adoptWatchdogRelease()

        XCTAssertFalse(manager.isActive)
        XCTAssertNil(manager.currentOptions)
        XCTAssertNil(manager.startedAt)
        XCTAssertTrue(mock.released.isEmpty, "the kernel already dropped them")
    }

    func testHeartbeatTicksWhileActive() async throws {
        let mock = MockSleepAssertionHolder()
        let wd = FakeAwakeWatchdog()
        let manager = CaffeinateManager(holder: mock, watchdog: wd, heartbeatInterval: 0.02)

        try manager.enable(options: allFlagsOptions())
        try? await Task.sleep(nanoseconds: 200_000_000)
        let during = wd.heartbeats
        manager.disable()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertGreaterThan(during, 0)
        XCTAssertEqual(wd.heartbeats, during, "heartbeat must stop with the assertion")
    }

    // MARK: mutual watch

    func testSilentWatchdogIsDetectedAndAssertionsReleased() async throws {
        let mock = MockSleepAssertionHolder()
        let wd = FakeAwakeWatchdog()
        let manager = CaffeinateManager(holder: mock, watchdog: wd, heartbeatInterval: 0.02)

        try manager.enable(options: allFlagsOptions())
        // The watchdog has not ticked in far longer than its own tick interval.
        wd.stubbedLastTickAge = 500

        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(manager.isActive, "a silent watchdog must not leave us unprotected")
        XCTAssertEqual(mock.released.count, 3)
    }

    func testHealthyWatchdogIsNotTreatedAsSilent() async throws {
        let mock = MockSleepAssertionHolder()
        let wd = FakeAwakeWatchdog()
        let manager = CaffeinateManager(holder: mock, watchdog: wd, heartbeatInterval: 0.02)

        try manager.enable(options: allFlagsOptions())
        wd.stubbedLastTickAge = 10

        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(manager.isActive)
    }

    /// A watchdog that fired cleanly stops ticking on purpose, so its last tick
    /// recedes without bound from that moment on. The mutual watch must not read
    /// that as death: the heartbeat continuation queued before a real main-actor
    /// stall runs the instant main recovers, ahead of the `.fired` event, and a
    /// `disable()` from here would flip `isActive` out from under the adopt path
    /// — losing the stall notification and the session close at `firedAt`.
    func testFiredWatchdogIsNotTreatedAsSilent() async throws {
        let mock = MockSleepAssertionHolder()
        let wd = FakeAwakeWatchdog()
        let manager = CaffeinateManager(holder: mock, watchdog: wd, heartbeatInterval: 0.02)

        try manager.enable(options: allFlagsOptions())
        // Both statements run without an await between them, so the heartbeat
        // task — which is `@MainActor`, like this test — cannot observe the
        // stale age against a still-armed watchdog.
        wd.stubbedLastTickAge = 500
        wd.simulateCleanFiring()

        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(wd.disarmCount, 0, "the mutual watch must not race the adopt path")
        XCTAssertTrue(mock.released.isEmpty, "the watchdog already released these")
        XCTAssertTrue(manager.isActive, "only adoptWatchdogRelease() may end this session")
    }
}

// MARK: - Off-main release recorder

/// Records what the stranded-release path hands to IOKit. Lives outside the
/// `SleepAssertionHolder` protocol on purpose: that protocol is documented as
/// non-Sendable, which is the whole reason the straggler path cannot use the
/// holder. This one is written from a background queue and read from the test's
/// main actor, so it locks.
private final class StrandedReleaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _released: [SleepAssertion] = []

    var released: [SleepAssertion] {
        lock.lock(); defer { lock.unlock() }; return _released
    }

    @discardableResult
    func record(_ assertion: SleepAssertion) -> Int32 {
        lock.lock(); _released.append(assertion); lock.unlock()
        return 0
    }

    /// Polls rather than signalling: the release is fire-and-forget by design,
    /// so there is no completion for the test to await.
    func waitForRelease(of assertion: SleepAssertion, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if released.contains(assertion) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return released.contains(assertion)
    }
}

// MARK: - Holder variant for the partial-rollback test

/// `MockSleepAssertionHolder` lets you throw exactly once via `nextAcquireError`,
/// but the rollback test needs the error on the Nth call regardless of state.
/// Small purpose-built variant that does that.
@MainActor
private final class CountingFailingHolder: SleepAssertionHolder {
    private(set) var acquired: [MockSleepAssertionHolder.AcquireRecord] = []
    private(set) var released: [SleepAssertion] = []
    private(set) var declareUserActivityCount: Int = 0
    private let failOnNthAcquire: Int
    private let error: Error
    private var nextID: UInt32 = 1
    private var acquireCallCount: Int = 0

    init(failOnNthAcquire: Int, error: Error) {
        self.failOnNthAcquire = failOnNthAcquire
        self.error = error
    }

    func acquire(_ type: SleepAssertionType, name: String) throws -> SleepAssertion {
        acquireCallCount += 1
        if acquireCallCount == failOnNthAcquire { throw error }
        let assertion = SleepAssertion(id: nextID, type: type)
        nextID += 1
        acquired.append(.init(type: type, name: name))
        return assertion
    }

    func release(_ assertion: SleepAssertion) { released.append(assertion) }
    func declareUserActivity(name: String) { declareUserActivityCount += 1 }
}

// MARK: - App Nap suppressor test double

/// Records begin/end calls and tracks live (unbalanced) suppressions so tests
/// can assert App Nap is held exactly across the caffeinated window.
private final class MockAppNapSuppressor: AppNapSuppressing {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var lastReason: String?
    var liveSuppressions: Int { beginCount - endCount }

    func begin(reason: String) -> NSObjectProtocol {
        beginCount += 1
        lastReason = reason
        return NSObject()
    }

    func end(_ token: NSObjectProtocol) {
        endCount += 1
    }
}
