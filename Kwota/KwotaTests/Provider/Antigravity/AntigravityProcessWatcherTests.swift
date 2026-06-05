//
//  AntigravityProcessWatcherTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class AntigravityProcessWatcherTests: XCTestCase {
    private func makeInfo(
        pid: Int32 = 12345,
        csrf: String = "abc123",
        ports: [Int] = [49838]
    ) -> AntigravityProcessInfo {
        AntigravityProcessInfo(pid: pid, csrfToken: csrf, listeningPorts: ports)
    }

    func test_emitsBaselineIdentity_whenProcessRunning() async {
        let info = makeInfo()
        let exp = expectation(description: "baseline emit")
        var captured: AntigravityIdentity?
        let watcher = AntigravityProcessWatcher(
            detect: { info },
            pollInterval: 100,
            probeWorkingPort: { _, ports, _ in ports.first }
        )
        watcher.onChange = { identity in
            captured = identity
            exp.fulfill()
        }
        watcher.start()
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured?.csrfToken, "abc123")
        XCTAssertEqual(captured?.port, 49838)
        XCTAssertFalse(captured?.credentialFingerprint.isEmpty ?? true)
        watcher.stop()
    }

    func test_emitsNil_whenNoProcess() async {
        let exp = expectation(description: "baseline nil emit")
        var captured: AntigravityIdentity?
        var emitted = false
        let watcher = AntigravityProcessWatcher(
            detect: { nil },
            pollInterval: 100,
            probeWorkingPort: { _, ports, _ in ports.first }
        )
        watcher.onChange = { identity in
            captured = identity
            emitted = true
            exp.fulfill()
        }
        watcher.start()
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertTrue(emitted)
        XCTAssertNil(captured)
        watcher.stop()
    }

    func test_emitsNewIdentity_whenCSRFRotates() async {
        let lock = NSLock()
        var currentInfo: AntigravityProcessInfo? = makeInfo(csrf: "csrf-A")
        let exp = expectation(description: "two emits")
        exp.expectedFulfillmentCount = 2
        var fingerprints: [String] = []
        let watcher = AntigravityProcessWatcher(
            detect: {
                lock.lock(); defer { lock.unlock() }
                return currentInfo
            },
            pollInterval: 0.05,
            probeWorkingPort: { _, ports, _ in ports.first }
        )
        watcher.onChange = { identity in
            if let identity { fingerprints.append(identity.credentialFingerprint) }
            exp.fulfill()
        }
        watcher.start()
        // Wait for baseline emit then rotate the CSRF
        try? await Task.sleep(nanoseconds: 150_000_000)
        lock.lock(); currentInfo = makeInfo(csrf: "csrf-B"); lock.unlock()
        await fulfillment(of: [exp], timeout: 3)
        XCTAssertEqual(fingerprints.count, 2)
        XCTAssertNotEqual(fingerprints[0], fingerprints[1])
        watcher.stop()
    }

    func test_emitsNil_whenProcessDisappears() async {
        let lock = NSLock()
        var currentInfo: AntigravityProcessInfo? = makeInfo()
        let exp = expectation(description: "two emits")
        exp.expectedFulfillmentCount = 2
        var emits: [AntigravityIdentity?] = []
        let watcher = AntigravityProcessWatcher(
            detect: {
                lock.lock(); defer { lock.unlock() }
                return currentInfo
            },
            pollInterval: 0.05,
            probeWorkingPort: { _, ports, _ in ports.first }
        )
        watcher.onChange = { identity in
            emits.append(identity)
            exp.fulfill()
        }
        watcher.start()
        try? await Task.sleep(nanoseconds: 150_000_000)
        lock.lock(); currentInfo = nil; lock.unlock()
        await fulfillment(of: [exp], timeout: 3)
        XCTAssertEqual(emits.count, 2)
        XCTAssertNotNil(emits[0])
        XCTAssertNil(emits[1])
        watcher.stop()
    }

    func test_debounce_sameIdentityDoesNotReEmit() async {
        var calls = 0
        let info = makeInfo()
        let watcher = AntigravityProcessWatcher(
            detect: { info },
            pollInterval: 0.05,
            probeWorkingPort: { _, ports, _ in ports.first }
        )
        watcher.onChange = { _ in calls += 1 }
        watcher.start()
        // Let several poll ticks fire on the unchanged identity.
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(calls, 1, "identical poll results should not re-emit")
        watcher.stop()
    }

    func test_picksFirstListeningPort_probeNotConsulted() async {
        // Production deliberately picks `info.listeningPorts.first` and does NOT
        // consult `probeWorkingPort`: the async probe path was observed to hang
        // under `-default-isolation=MainActor` (see the comment in
        // `AntigravityProcessWatcher.recompute()`), and the API client retries
        // HTTP→HTTPS anyway, so a wrong port costs one round-trip, not correctness.
        // This test pins that behavior — even a probe that prefers 49839 is
        // ignored, and the emitted identity uses the first listening port (49838).
        let info = makeInfo(ports: [49838, 49839])
        let exp = expectation(description: "emit")
        var captured: AntigravityIdentity?
        let watcher = AntigravityProcessWatcher(
            detect: { info },
            pollInterval: 100,
            probeWorkingPort: { _, ports, _ in
                ports.contains(49839) ? 49839 : ports.first
            }
        )
        watcher.onChange = { identity in
            captured = identity
            exp.fulfill()
        }
        watcher.start()
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(captured?.port, 49838)
        watcher.stop()
    }

    /// Box so the `@Sendable` detect closure can read a value that the test
    /// later mutates, without tripping the Swift-6 captured-var warnings the
    /// NSLock-based helpers above incur.
    private final class InfoBox: @unchecked Sendable {
        var info: AntigravityProcessInfo?
        init(_ info: AntigravityProcessInfo?) { self.info = info }
    }

    func test_currentPID_tracksDetectedProcess() async {
        let box = InfoBox(makeInfo(pid: 4242))
        let exp = expectation(description: "two emits")
        exp.expectedFulfillmentCount = 2
        let watcher = AntigravityProcessWatcher(
            detect: { box.info },
            pollInterval: 0.05,
            probeWorkingPort: { _, ports, _ in ports.first }
        )
        watcher.onChange = { _ in exp.fulfill() }
        watcher.start()
        // Baseline detect runs synchronously in start(): pid is set immediately.
        XCTAssertEqual(watcher.currentPID, 4242)
        // Drop the process; once the watcher emits nil, currentPID clears too.
        try? await Task.sleep(nanoseconds: 150_000_000)
        box.info = nil
        await fulfillment(of: [exp], timeout: 3)
        XCTAssertNil(watcher.currentPID)
        watcher.stop()
    }

    func test_pokeNow_appliesAsynchronously() async {
        // pokeNow runs detect() off the MainActor and applies after a hop, so
        // popover-open never blocks the main thread. Right after the call the
        // identity must NOT yet be applied; it lands once onChange fires.
        let box = InfoBox(makeInfo(pid: 4242))
        let applied = expectation(description: "pokeNow applied")
        let watcher = AntigravityProcessWatcher(
            detect: { box.info },
            pollInterval: 100,
            probeWorkingPort: { _, ports, _ in ports.first }
        )
        watcher.onChange = { _ in applied.fulfill() }
        watcher.pokeNow()
        XCTAssertNil(watcher.currentPID, "pokeNow must not block/apply synchronously")
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(watcher.currentPID, 4242)
        watcher.stop()
    }

    // MARK: - Poll cadence (popover-aware backoff)

    func test_pollCadence_defaultsToClosedInterval_atLaunch() {
        // The popover is closed at launch, so the watcher must poll at the slow
        // closed cadence rather than spawning pgrep/ps/lsof every openInterval
        // seconds forever. This is the energy fix: an idle app polls at 60s.
        let watcher = AntigravityProcessWatcher(
            detect: { nil },
            openInterval: 5,
            closedInterval: 60,
            probeWorkingPort: { _, ports, _ in ports.first }
        )
        XCTAssertEqual(watcher.currentInterval, 60)
    }

    func test_pollCadence_followsPopoverState() {
        // popoverDidOpen speeds detection up to the open cadence; popoverDidClose
        // backs it off again — mirroring UsageRefreshCoordinator's open/closed
        // interval switch so process polling doesn't run hot while idle.
        let watcher = AntigravityProcessWatcher(
            detect: { nil },
            openInterval: 5,
            closedInterval: 60,
            probeWorkingPort: { _, ports, _ in ports.first }
        )
        watcher.popoverDidOpen()
        XCTAssertEqual(watcher.currentInterval, 5)
        watcher.popoverDidClose()
        XCTAssertEqual(watcher.currentInterval, 60)
    }

    func test_probeWorkingPort_fallsBackWhenNil() async {
        let info = makeInfo(ports: [49838, 49839])
        let exp = expectation(description: "emit")
        var captured: AntigravityIdentity?
        let watcher = AntigravityProcessWatcher(
            detect: { info },
            pollInterval: 100,
            probeWorkingPort: { _, _, _ in nil }
        )
        watcher.onChange = { identity in
            captured = identity
            exp.fulfill()
        }
        watcher.start()
        await fulfillment(of: [exp], timeout: 2)
        // Probe returned nil → fall back to listeningPorts.first.
        XCTAssertEqual(captured?.port, 49838)
        watcher.stop()
    }
}
