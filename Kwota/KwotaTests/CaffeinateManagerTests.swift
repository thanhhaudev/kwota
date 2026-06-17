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
