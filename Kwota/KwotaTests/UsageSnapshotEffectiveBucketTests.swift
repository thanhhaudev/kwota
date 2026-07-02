//
//  UsageSnapshotEffectiveBucketTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class UsageSnapshotEffectiveBucketTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        fiveHour: UsageBucket,
        sevenDay: UsageBucket,
        opus: UsageBucket? = nil,
        sonnet: UsageBucket? = nil,
        omelette: UsageBucket? = nil,
        fable: UsageBucket? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDayOpus: opus,
            sevenDaySonnet: sonnet,
            sevenDayOmelette: omelette,
            sevenDayFable: fable,
            extra: nil,
            fetchedAt: now.addingTimeInterval(-3600)
        )
    }

    func testFiveHourClampsToZeroWhenResetsAtIsPast() {
        let s = snapshot(
            fiveHour: UsageBucket(utilization: 98, resetsAt: now.addingTimeInterval(-60)),
            sevenDay: UsageBucket(utilization: 50, resetsAt: now.addingTimeInterval(86400))
        )
        XCTAssertEqual(s.effectiveFiveHour(now: now).utilization, 0)
        XCTAssertEqual(s.effectiveFiveHour(now: now).resetsAt, s.fiveHour.resetsAt)
    }

    func testFiveHourPreservedWhenResetsAtIsFuture() {
        let s = snapshot(
            fiveHour: UsageBucket(utilization: 42, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 12, resetsAt: now.addingTimeInterval(86400))
        )
        XCTAssertEqual(s.effectiveFiveHour(now: now), s.fiveHour)
    }

    func testFiveHourPreservedWhenResetsAtIsNil() {
        let s = snapshot(
            fiveHour: UsageBucket(utilization: 73, resetsAt: nil),
            sevenDay: UsageBucket(utilization: 12, resetsAt: now.addingTimeInterval(86400))
        )
        XCTAssertEqual(s.effectiveFiveHour(now: now), s.fiveHour)
    }

    func testSevenDayClampsToZeroWhenResetsAtIsPast() {
        let s = snapshot(
            fiveHour: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 81, resetsAt: now.addingTimeInterval(-60))
        )
        XCTAssertEqual(s.effectiveSevenDay(now: now).utilization, 0)
    }

    func testEffectiveOpusAndSonnetClampToZeroWhenPast() {
        let past = UsageBucket(utilization: 60, resetsAt: now.addingTimeInterval(-1))
        let s = snapshot(
            fiveHour: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(86400)),
            opus: past,
            sonnet: past
        )
        XCTAssertEqual(s.effectiveSevenDayOpus(now: now)?.utilization, 0)
        XCTAssertEqual(s.effectiveSevenDaySonnet(now: now)?.utilization, 0)
    }

    func testEffectiveOpusAndSonnetReturnNilWhenSourceNil() {
        let s = snapshot(
            fiveHour: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(86400)),
            opus: nil,
            sonnet: nil
        )
        XCTAssertNil(s.effectiveSevenDayOpus(now: now))
        XCTAssertNil(s.effectiveSevenDaySonnet(now: now))
    }

    func testEffectiveOpusPreservedWhenFuture() {
        let future = UsageBucket(utilization: 30, resetsAt: now.addingTimeInterval(86400))
        let s = snapshot(
            fiveHour: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(86400)),
            opus: future
        )
        XCTAssertEqual(s.effectiveSevenDayOpus(now: now), future)
    }

    // MARK: - "Claude Design" / sevenDayOmelette

    func testEffectiveOmeletteClampsToZeroWhenPast() {
        let past = UsageBucket(utilization: 8, resetsAt: now.addingTimeInterval(-1))
        let s = snapshot(
            fiveHour: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(86400)),
            omelette: past
        )
        XCTAssertEqual(s.effectiveSevenDayOmelette(now: now)?.utilization, 0)
    }

    func testEffectiveOmeletteReturnsNilWhenSourceNil() {
        let s = snapshot(
            fiveHour: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(86400)),
            omelette: nil
        )
        XCTAssertNil(s.effectiveSevenDayOmelette(now: now))
    }

    func testEffectiveOmeletteIsIndependentOfOpusAndSonnet() {
        // Regression: account in screenshot has Sonnet+Omelette but Opus=null.
        // Make sure the omelette accessor doesn't accidentally inherit nilness
        // from a sibling field.
        let future = UsageBucket(utilization: 8, resetsAt: now.addingTimeInterval(86400))
        let s = snapshot(
            fiveHour: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(86400)),
            opus: nil,
            sonnet: nil,
            omelette: future
        )
        XCTAssertEqual(s.effectiveSevenDayOmelette(now: now), future)
        XCTAssertNil(s.effectiveSevenDayOpus(now: now))
        XCTAssertNil(s.effectiveSevenDaySonnet(now: now))
    }

    // MARK: - "Fable only" / sevenDayFable

    func testEffectiveFableClampsToZeroWhenPast() {
        let past = UsageBucket(utilization: 11, resetsAt: now.addingTimeInterval(-1))
        let s = snapshot(
            fiveHour: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(86400)),
            fable: past
        )
        XCTAssertEqual(s.effectiveSevenDayFable(now: now)?.utilization, 0)
    }

    func testEffectiveFableReturnsNilWhenSourceNil() {
        let s = snapshot(
            fiveHour: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(86400)),
            fable: nil
        )
        XCTAssertNil(s.effectiveSevenDayFable(now: now))
    }
}
