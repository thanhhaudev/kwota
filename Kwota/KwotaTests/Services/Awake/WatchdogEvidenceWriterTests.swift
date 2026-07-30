//
//  WatchdogEvidenceWriterTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class WatchdogEvidenceWriterTests: XCTestCase {

    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("awake-watchdog-events.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func firing(at seconds: TimeInterval) -> WatchdogEvent {
        .fired(WatchdogFiring(
            firedAt: Date(timeIntervalSince1970: seconds),
            reason: .stalled,
            mode: .auto,
            sessionStart: Date(timeIntervalSince1970: 0),
            heldSeconds: seconds,
            mainStallSeconds: 400,
            batteryPercent: 55,
            isOnBattery: true,
            assertionIDs: [7],
            releaseStatuses: [0]
        ))
    }

    func test_appendRoundTrips() throws {
        let writer = FileWatchdogEvidenceWriter(url: url)
        writer.append(firing(at: 100))

        let events = try FileWatchdogEvidenceWriter.load(from: url)
        XCTAssertEqual(events, [firing(at: 100)])
    }

    func test_appendPreservesOrderNewestLast() throws {
        let writer = FileWatchdogEvidenceWriter(url: url)
        writer.append(firing(at: 100))
        writer.append(firing(at: 200))

        let events = try FileWatchdogEvidenceWriter.load(from: url)
        XCTAssertEqual(events, [firing(at: 100), firing(at: 200)])
    }

    func test_ringDropsOldestBeyondMaxRecords() throws {
        let writer = FileWatchdogEvidenceWriter(url: url, maxRecords: 3)
        for i in 1...5 { writer.append(firing(at: TimeInterval(i))) }

        let events = try FileWatchdogEvidenceWriter.load(from: url)
        XCTAssertEqual(events, [firing(at: 3), firing(at: 4), firing(at: 5)])
    }

    func test_allThreeEventKindsRoundTrip() throws {
        let writer = FileWatchdogEvidenceWriter(url: url)
        let stall = WatchdogEvent.stallObserved(WatchdogStall(
            observedAt: Date(timeIntervalSince1970: 10), side: .mainActor, seconds: 240
        ))
        let nudge = WatchdogEvent.untimedOnBatteryNudge(hours: 2)
        writer.append(firing(at: 1))
        writer.append(stall)
        writer.append(nudge)

        let events = try FileWatchdogEvidenceWriter.load(from: url)
        XCTAssertEqual(events, [firing(at: 1), stall, nudge])
    }

    func test_corruptFileIsReplacedNotPropagated() throws {
        try Data("not json".utf8).write(to: url)
        let writer = FileWatchdogEvidenceWriter(url: url)
        writer.append(firing(at: 1))

        let events = try FileWatchdogEvidenceWriter.load(from: url)
        XCTAssertEqual(events, [firing(at: 1)], "a corrupt file must not swallow new evidence")
    }

    func test_unwritablePathDoesNotThrow() {
        let bad = URL(fileURLWithPath: "/dev/null/nope/events.json")
        let writer = FileWatchdogEvidenceWriter(url: bad)
        writer.append(firing(at: 1))   // must not trap; the release matters more
    }
}
