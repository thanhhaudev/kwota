//
//  BatteryMonitorTests.swift
//  KwotaTests
//

import XCTest
import Combine
@testable import Kwota

@MainActor
final class BatteryMonitorTests: XCTestCase {

    /// Test-controlled power source. The value is whatever the test last wrote,
    /// and `sampleCount` records how many times the monitor actually read it.
    ///
    /// Asserting on `sampleCount` is the point: an earlier draft of these tests
    /// used an auto-advancing readings array, which meant every assertion was
    /// satisfied by the refresh inside `start()` before any poll tick ran. Four
    /// of five tests passed identically with the entire poll mechanism deleted.
    /// Count the reads, not just the value.
    final class FakePowerSource: @unchecked Sendable {
        private let lock = NSLock()
        private var value: BatteryReading
        private var count = 0

        init(_ initial: BatteryReading) { self.value = initial }

        var sampleCount: Int { lock.lock(); defer { lock.unlock() }; return count }

        func set(_ next: BatteryReading) {
            lock.lock(); defer { lock.unlock() }; value = next
        }

        func read() -> BatteryReading {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return value
        }
    }

    private func makeMonitor(
        source: FakePowerSource,
        pollInterval: TimeInterval = 0.01
    ) -> IOPowerSourcesBatteryMonitor {
        IOPowerSourcesBatteryMonitor(
            pollInterval: pollInterval,
            sampler: { source.read() },
            installRunLoopSource: false
        )
    }

    private let charged = BatteryReading(isOnBattery: false, percent: 100)
    private let low = BatteryReading(isOnBattery: true, percent: 12)

    func test_noPolling_whenPopoverClosedAndNothingCaffeinated() async {
        let source = FakePowerSource(charged)
        let monitor = makeMonitor(source: source)
        monitor.start()
        let afterStart = source.sampleCount

        source.set(low)
        try? await Task.sleep(nanoseconds: 100_000_000)   // ~10 poll intervals

        XCTAssertEqual(source.sampleCount, afterStart, "no demand must mean no reads at all")
        XCTAssertEqual(monitor.reading.percent, 100)
    }

    func test_pollsWhilePopoverOpen() async {
        let source = FakePowerSource(charged)
        let monitor = makeMonitor(source: source)
        monitor.start()
        monitor.setPopoverOpen(true)
        let afterOpen = source.sampleCount

        source.set(low)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertGreaterThan(source.sampleCount, afterOpen)
        XCTAssertEqual(monitor.reading.percent, 12)
    }

    /// The F-003 shape: popover closed, assertion held. A popover-only gate
    /// would poll nothing here, which is exactly when the threshold matters.
    func test_pollsWhileAssertionHeld_evenWithPopoverClosed() async {
        let source = FakePowerSource(charged)
        let monitor = makeMonitor(source: source)
        monitor.start()
        monitor.setAssertionHeld(true)
        let afterArm = source.sampleCount

        source.set(low)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertGreaterThan(source.sampleCount, afterArm)
        XCTAssertEqual(monitor.reading.percent, 12)
    }

    func test_pollKeepsRunningWhileEitherConditionHolds() async {
        let source = FakePowerSource(charged)
        let monitor = makeMonitor(source: source)
        monitor.start()
        monitor.setPopoverOpen(true)
        monitor.setAssertionHeld(true)
        monitor.setPopoverOpen(false)   // one condition drops, the other holds
        let afterDrop = source.sampleCount

        source.set(low)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertGreaterThan(source.sampleCount, afterDrop)
        XCTAssertEqual(monitor.reading.percent, 12)
    }

    func test_pollStopsWhenBothConditionsClear() async {
        let source = FakePowerSource(charged)
        let monitor = makeMonitor(source: source)
        monitor.start()
        monitor.setPopoverOpen(true)
        monitor.setAssertionHeld(true)
        monitor.setPopoverOpen(false)
        monitor.setAssertionHeld(false)
        let afterStop = source.sampleCount

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(source.sampleCount, afterStop, "demand gone, polling must stop")
    }

    func test_openingPopoverRefreshesImmediately() {
        let source = FakePowerSource(charged)
        // Poll far away, so only the immediate refresh on open can change it.
        let monitor = makeMonitor(source: source, pollInterval: 3600)
        monitor.start()

        source.set(low)
        monitor.setPopoverOpen(true)

        XCTAssertEqual(monitor.reading.percent, 12, "first frame must never be stale")
    }
}
