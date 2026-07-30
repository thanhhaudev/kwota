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

    private func stall(at seconds: TimeInterval) -> WatchdogEvent {
        .stallObserved(WatchdogStall(
            observedAt: Date(timeIntervalSince1970: seconds), side: .mainActor, seconds: 240
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

    // MARK: shared budget — breadcrumbs must never evict forensics

    /// The dangerous direction. A firing is recorded, and then the session keeps
    /// running and keeps producing `.stallObserved` breadcrumbs — one per stall
    /// episode, re-armable by every heartbeat, so a user stepping away
    /// repeatedly generates them all afternoon with no freeze involved. Under
    /// plain FIFO those breadcrumbs push the firing out of the ring, which would
    /// mean this branch's own diagnostics destroying the F-003 forensics the
    /// branch exists to capture.
    func test_stallsArrivingAfterAFiringNeverEvictIt() throws {
        let writer = FileWatchdogEvidenceWriter(url: url, maxRecords: 3)
        writer.append(firing(at: 1))
        for i in 1...20 { writer.append(stall(at: TimeInterval(i))) }

        let events = try FileWatchdogEvidenceWriter.load(from: url)
        XCTAssertEqual(
            events, [firing(at: 1), stall(at: 19), stall(at: 20)],
            "the firing must survive 20 breadcrumbs in a 3-slot ring; the breadcrumbs are what gets sacrificed"
        )
    }

    /// The other direction: breadcrumbs already fill the ring when the firing
    /// finally lands. It must still make it in, evicting a breadcrumb rather
    /// than being dropped or forcing the newest record out.
    func test_aFiringLandingIntoARingFullOfStallsIsRetained() throws {
        let writer = FileWatchdogEvidenceWriter(url: url, maxRecords: 3)
        for i in 1...10 { writer.append(stall(at: TimeInterval(i))) }
        writer.append(firing(at: 500))

        let events = try FileWatchdogEvidenceWriter.load(from: url)
        XCTAssertEqual(events, [stall(at: 9), stall(at: 10), firing(at: 500)])
        XCTAssertTrue(events.contains(firing(at: 500)))
    }

    /// Priority, not a fixed reservation: once no breadcrumb is left to
    /// sacrifice, firings evict firings under the original oldest-first rule.
    /// A ring full of firings needs no footnotes.
    func test_firingsEvictFiringsOnceNoBreadcrumbsAreLeft() throws {
        let writer = FileWatchdogEvidenceWriter(url: url, maxRecords: 2)
        writer.append(stall(at: 1))
        writer.append(firing(at: 1))
        writer.append(firing(at: 2))   // sacrifices the breadcrumb
        writer.append(firing(at: 3))   // nothing left to sacrifice: oldest firing goes

        let events = try FileWatchdogEvidenceWriter.load(from: url)
        XCTAssertEqual(events, [firing(at: 2), firing(at: 3)])
    }

    /// A session that never stalls must not pay for the priority rule: all
    /// `maxRecords` slots stay available to firings, exactly as before.
    func test_noBreadcrumbsMeansTheRingBehavesExactlyAsBefore() throws {
        let writer = FileWatchdogEvidenceWriter(url: url, maxRecords: 3)
        for i in 1...5 { writer.append(firing(at: TimeInterval(i))) }

        let events = try FileWatchdogEvidenceWriter.load(from: url)
        XCTAssertEqual(events, [firing(at: 3), firing(at: 4), firing(at: 5)])
    }

    func test_nudgesAreEvictedBeforeFiringsToo() throws {
        let writer = FileWatchdogEvidenceWriter(url: url, maxRecords: 2)
        writer.append(firing(at: 1))
        writer.append(.untimedOnBatteryNudge(hours: 2))
        writer.append(.untimedOnBatteryNudge(hours: 5))

        let events = try FileWatchdogEvidenceWriter.load(from: url)
        XCTAssertEqual(events, [firing(at: 1), .untimedOnBatteryNudge(hours: 5)])
    }
}
