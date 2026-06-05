//
//  ActivityChartCardSegmentAccessibilityTests.swift
//  KwotaTests
//
//  Renamed conceptually: the file still hosts the ActivityChartCard test
//  suite, but the old per-session segment accessibility helpers were
//  retired when the chart switched to a continuous bucketed wave. New
//  tests below cover the helpers that drive the wave + footer chip.
//

import XCTest
import SwiftUI
@testable import Kwota

final class ActivityChartCardSegmentAccessibilityTests: XCTestCase {

    // MARK: - Helpers

    private func date(_ hoursAgoFromAnchor: Double, anchor: Date) -> Date {
        anchor.addingTimeInterval(-hoursAgoFromAnchor * 3600)
    }

    private var anchor: Date {
        // Fixed anchor so tests don't depend on `Date()`.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 16
        comps.hour = 12; comps.minute = 0
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    // MARK: - bandColor

    func test_bandColor_autoIsGreen_manualIsAwakeManualAsset() {
        XCTAssertEqual(ActivityChartCard.bandColor(for: .auto), .green)
        XCTAssertEqual(ActivityChartCard.bandColor(for: .manual), Color("AwakeManual"))
    }

    // MARK: - awakeIntervals

    func testAwakeIntervals_clipsToWindow() {
        let now = anchor
        let windowStart = date(8, anchor: now)
        let session = AwakeSession(
            mode: .auto,
            start: date(9, anchor: now),
            end: date(7, anchor: now)
        )
        let result = ActivityChartCard.awakeIntervals(
            sessions: [session],
            windowStart: windowStart,
            now: now
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].start, windowStart)
        XCTAssertEqual(result[0].end, date(7, anchor: now))
    }

    func testAwakeIntervals_filtersPreWindowSessions() {
        let now = anchor
        let windowStart = date(8, anchor: now)
        let session = AwakeSession(
            mode: .auto,
            start: date(10, anchor: now),
            end: date(9, anchor: now)
        )
        let result = ActivityChartCard.awakeIntervals(
            sessions: [session],
            windowStart: windowStart,
            now: now
        )
        XCTAssertEqual(result.count, 0)
    }

    func testAwakeIntervals_clampsOngoingEndToNow() {
        let now = anchor
        let windowStart = date(8, anchor: now)
        let session = AwakeSession(
            mode: .manual,
            start: date(1, anchor: now),
            end: nil
        )
        let result = ActivityChartCard.awakeIntervals(
            sessions: [session],
            windowStart: windowStart,
            now: now
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].end, now)
        XCTAssertEqual(result[0].mode, .manual)
    }

    // MARK: - eventBuckets

    func testEventBuckets_distributesTimestampsAcrossDenseGrid() {
        let now = anchor
        let windowStart = date(1, anchor: now)
        let bucketSize: TimeInterval = 5 * 60   // 5min
        // 3 events: one near start, two inside the same later bucket
        let ts: [Date] = [
            windowStart.addingTimeInterval(60),       // bucket 0
            windowStart.addingTimeInterval(40 * 60),  // bucket 8
            windowStart.addingTimeInterval(40 * 60 + 10)
        ]
        let buckets = ActivityChartCard.eventBuckets(
            timestamps: ts,
            windowStart: windowStart,
            now: now,
            bucketSize: bucketSize
        )
        XCTAssertEqual(buckets.count, 12) // 1h / 5min
        XCTAssertEqual(buckets[0].count, 1)
        XCTAssertEqual(buckets[8].count, 2)
        XCTAssertEqual(buckets[1].count, 0)
    }

    func testEventBuckets_emptyArrayForEmptyWindow() {
        let now = anchor
        let buckets = ActivityChartCard.eventBuckets(
            timestamps: [],
            windowStart: now,
            now: now,
            bucketSize: 60
        )
        XCTAssertEqual(buckets.count, 0)
    }

    // MARK: - windowStats

    func testWindowStats_splitsAwakeByMode() {
        let now = anchor
        let windowStart = date(8, anchor: now)
        let sessions: [AwakeSession] = [
            AwakeSession(mode: .auto,   start: date(7, anchor: now), end: date(6, anchor: now)),   // 1h
            AwakeSession(mode: .manual, start: date(5, anchor: now), end: date(3, anchor: now)),   // 2h
            AwakeSession(mode: .auto,   start: date(1, anchor: now), end: nil),                    // 1h ongoing
        ]
        let timestamps: [Date] = [
            date(6.5, anchor: now), date(4, anchor: now), date(0.5, anchor: now)
        ]
        let stats = ActivityChartCard.windowStats(
            sessions: sessions,
            providerTimestamps: [(provider: .claude, timestamps: timestamps)],
            windowStart: windowStart,
            now: now
        )
        XCTAssertEqual(stats.awakeAuto, 2 * 3600, accuracy: 0.5)
        XCTAssertEqual(stats.awakeManual, 2 * 3600, accuracy: 0.5)
        XCTAssertEqual(stats.totalAwake, 4 * 3600, accuracy: 0.5)
        XCTAssertEqual(
            stats.providerCounts,
            [ActivityChartCard.ProviderCount(provider: .claude, count: 3)]
        )
    }

    func testWindowStats_excludesTimestampsOutsideWindow() {
        let now = anchor
        let windowStart = date(8, anchor: now)
        let timestamps: [Date] = [
            date(10, anchor: now), // before window
            date(4, anchor: now),  // inside
            now.addingTimeInterval(60) // after now
        ]
        let stats = ActivityChartCard.windowStats(
            sessions: [],
            providerTimestamps: [(provider: .claude, timestamps: timestamps)],
            windowStart: windowStart,
            now: now
        )
        XCTAssertEqual(
            stats.providerCounts,
            [ActivityChartCard.ProviderCount(provider: .claude, count: 1)]
        )
    }

    // MARK: - footerText

    func testFooterText_emptyState() {
        let stats = ActivityChartCard.WindowStats(
            awakeAuto: 0, awakeManual: 0, providerCounts: []
        )
        XCTAssertEqual(
            ActivityChartCard.footerText(stats: stats),
            "No activity in the last 8h"
        )
    }

    func testFooterText_dualModeWithEvents() {
        let stats = ActivityChartCard.WindowStats(
            awakeAuto: 4 * 3600 + 30 * 60,
            awakeManual: 1 * 3600,
            providerCounts: [ActivityChartCard.ProviderCount(provider: .claude, count: 60)]
        )
        XCTAssertEqual(
            ActivityChartCard.footerText(stats: stats),
            "Awake for 5h 30m · 60 events"
        )
    }

    func testFooterText_autoOnlyDoesNotMentionAuto() {
        let stats = ActivityChartCard.WindowStats(
            awakeAuto: 2 * 3600,
            awakeManual: 0,
            providerCounts: [ActivityChartCard.ProviderCount(provider: .claude, count: 5)]
        )
        XCTAssertEqual(
            ActivityChartCard.footerText(stats: stats),
            "Awake for 2h · 5 events"
        )
    }

    func testFooterText_singleEventStillPlural() {
        let stats = ActivityChartCard.WindowStats(
            awakeAuto: 2 * 3600,
            awakeManual: 0,
            providerCounts: [ActivityChartCard.ProviderCount(provider: .claude, count: 1)]
        )
        XCTAssertEqual(
            ActivityChartCard.footerText(stats: stats),
            "Awake for 2h · 1 events"
        )
    }

    func testFooterText_largeCountUsesGrouping() {
        let stats = ActivityChartCard.WindowStats(
            awakeAuto: 2 * 3600,
            awakeManual: 0,
            providerCounts: [ActivityChartCard.ProviderCount(provider: .claude, count: 1_234)]
        )
        XCTAssertEqual(
            ActivityChartCard.footerText(stats: stats),
            "Awake for 2h · 1,234 events"
        )
    }

    func testFooterText_multiProvider_perProviderEvents() {
        let stats = ActivityChartCard.WindowStats(
            awakeAuto: 3 * 3600 + 12 * 60, awakeManual: 0,
            providerCounts: [
                ActivityChartCard.ProviderCount(provider: .claude, count: 3_005),
                ActivityChartCard.ProviderCount(provider: .codex, count: 142),
            ]
        )
        XCTAssertEqual(
            ActivityChartCard.footerText(stats: stats),
            "Awake for 3h 12m · Claude 3,005 · Codex 142 events"
        )
    }

    func testFooterText_soleNonClaude_showsProviderName() {
        let stats = ActivityChartCard.WindowStats(
            awakeAuto: 3 * 3600 + 12 * 60, awakeManual: 0,
            providerCounts: [ActivityChartCard.ProviderCount(provider: .codex, count: 142)]
        )
        XCTAssertEqual(
            ActivityChartCard.footerText(stats: stats),
            "Awake for 3h 12m · Codex 142 events"
        )
    }

    func testFooterText_soleClaude_omitsName() {
        let stats = ActivityChartCard.WindowStats(
            awakeAuto: 0, awakeManual: 0,
            providerCounts: [ActivityChartCard.ProviderCount(provider: .claude, count: 3_005)]
        )
        XCTAssertEqual(
            ActivityChartCard.footerText(stats: stats),
            "3,005 events"
        )
    }

    // MARK: - computeYMax (outlier-resistant Y ceiling)

    private func bucket(_ count: Int) -> ActivityChartCard.EventBucket {
        ActivityChartCard.EventBucket(start: anchor, count: count)
    }

    func testComputeYMax_emptyBucketsReturnsOne() {
        XCTAssertEqual(ActivityChartCard.computeYMax(buckets: []), 1)
    }

    func testComputeYMax_allZeroReturnsOne() {
        let buckets = (0..<10).map { _ in bucket(0) }
        XCTAssertEqual(ActivityChartCard.computeYMax(buckets: buckets), 1)
    }

    func testComputeYMax_smallSampleUsesRawMax() {
        // 3 non-zero buckets is below the 4-sample threshold for percentile
        // analysis → returns rawMax (=3) so a sparse session still renders.
        let buckets = [bucket(1), bucket(2), bucket(3), bucket(0)]
        XCTAssertEqual(ActivityChartCard.computeYMax(buckets: buckets), 3)
    }

    func testComputeYMax_capsOutlierBurst() {
        // 10 ones + one 50-bucket burst: p75 of non-zero = 1, cap = 2.
        // Raw max (50) > cap (2) → ceiling at 2 so the small humps stay
        // visible instead of being squashed by the outlier.
        var buckets = (0..<10).map { _ in bucket(1) }
        buckets.append(bucket(50))
        XCTAssertEqual(ActivityChartCard.computeYMax(buckets: buckets), 2)
    }

    func testComputeYMax_keepsModeratePeak() {
        // Distribution where the max is within 2× of p75 — no capping.
        let buckets = [bucket(1), bucket(2), bucket(2), bucket(3), bucket(4), bucket(5)]
        // sorted = [1,2,2,3,4,5], p75 idx = int(6*0.75)=4 → sorted[4]=4. cap=8.
        // rawMax=5 ≤ cap → returns 5.
        XCTAssertEqual(ActivityChartCard.computeYMax(buckets: buckets), 5)
    }

    // MARK: - chartAccessibilityValue

    func testChartAccessibilityValue_emptyState() {
        let stats = ActivityChartCard.WindowStats(awakeAuto: 0, awakeManual: 0, providerCounts: [])
        XCTAssertEqual(
            ActivityChartCard.chartAccessibilityValue(stats: stats),
            "No activity in the last 8h"
        )
    }

    func testChartAccessibilityValue_dualMode() {
        let stats = ActivityChartCard.WindowStats(
            awakeAuto: 4 * 3600 + 30 * 60,
            awakeManual: 1 * 3600,
            providerCounts: [ActivityChartCard.ProviderCount(provider: .claude, count: 60)]
        )
        XCTAssertEqual(
            ActivityChartCard.chartAccessibilityValue(stats: stats),
            "60 events, Mac awake for 5h 30m, 4h 30m auto, 1h manual"
        )
    }

    func testChartAccessibilityValue_singleEventStillPlural() {
        let stats = ActivityChartCard.WindowStats(
            awakeAuto: 30 * 60,
            awakeManual: 0,
            providerCounts: [ActivityChartCard.ProviderCount(provider: .claude, count: 1)]
        )
        XCTAssertEqual(
            ActivityChartCard.chartAccessibilityValue(stats: stats),
            "1 events, Mac awake for 30m"
        )
    }

    // MARK: - displayWindow

    func testDisplayWindow_noOpenSessionsReturnsDefault() {
        let now = anchor
        // No sessions at all
        XCTAssertEqual(
            ActivityChartCard.displayWindow(now: now, sessions: []),
            8 * 3600
        )
        // One closed session, no open sessions
        let closed = AwakeSession(
            mode: .auto,
            start: date(10, anchor: now),
            end: date(2, anchor: now)
        )
        XCTAssertEqual(
            ActivityChartCard.displayWindow(now: now, sessions: [closed]),
            8 * 3600
        )
    }

    func testDisplayWindow_openSessionWithinDefaultReturnsDefault() {
        let now = anchor
        let open = AwakeSession(
            mode: .auto,
            start: date(4, anchor: now),   // 4h ago
            end: nil
        )
        XCTAssertEqual(
            ActivityChartCard.displayWindow(now: now, sessions: [open]),
            8 * 3600
        )
    }

    func testDisplayWindow_openSessionBeyondDefaultExtends() {
        let now = anchor
        let open = AwakeSession(
            mode: .auto,
            start: date(12, anchor: now),  // 12h ago
            end: nil
        )
        XCTAssertEqual(
            ActivityChartCard.displayWindow(now: now, sessions: [open]),
            12 * 3600
        )
    }

    func testDisplayWindow_clampsAtMax() {
        let now = anchor
        let open = AwakeSession(
            mode: .auto,
            start: date(30, anchor: now),  // 30h ago — beyond 24h cap
            end: nil
        )
        XCTAssertEqual(
            ActivityChartCard.displayWindow(now: now, sessions: [open]),
            24 * 3600
        )
    }

    func testDisplayWindow_picksOldestOpen() {
        let now = anchor
        let older = AwakeSession(
            mode: .auto,
            start: date(14, anchor: now),  // 14h ago
            end: nil
        )
        let newer = AwakeSession(
            mode: .manual,
            start: date(10, anchor: now),  // 10h ago
            end: nil
        )
        XCTAssertEqual(
            ActivityChartCard.displayWindow(now: now, sessions: [newer, older]),
            14 * 3600
        )
    }

    // MARK: - window-aware footer & a11y

    func testFooterText_omitsWindowEvenWhenExtended() {
        // The x-axis already shows the span, so the footer carries no "Past Nh"
        // prefix — not at the default window, nor an extended one.
        let stats = ActivityChartCard.WindowStats(
            awakeAuto: 9 * 3600, awakeManual: 0,
            providerCounts: [ActivityChartCard.ProviderCount(provider: .claude, count: 60)]
        )
        XCTAssertEqual(
            ActivityChartCard.footerText(stats: stats, window: 12 * 3600),
            "Awake for 9h · 60 events"
        )
    }

    func testChartAccessibilityValue_extendedWindow() {
        let stats = ActivityChartCard.WindowStats(
            awakeAuto: 7 * 3600, awakeManual: 2 * 3600,
            providerCounts: [ActivityChartCard.ProviderCount(provider: .claude, count: 60)]
        )
        XCTAssertEqual(
            ActivityChartCard.chartAccessibilityValue(stats: stats, window: 12 * 3600),
            "Past 12h. 60 events, Mac awake for 9h, 7h auto, 2h manual"
        )
    }

    // MARK: - normalizedWave / usesMultiWave

    func test_normalizedWave_scalesToGivenMax() {
        let now = anchor
        let windowStart = date(8, anchor: now)
        // Three timestamps in one 5-min bucket; one elsewhere. maxCount = 3.
        let ts = [
            date(7.0, anchor: now),
            date(3.0, anchor: now), date(3.0, anchor: now), date(3.0, anchor: now),
        ]
        let points = ActivityChartCard.normalizedWave(
            timestamps: ts, windowStart: windowStart, now: now, bucketSize: 5 * 60, maxCount: 3)
        let maxValue = points.map(\.value).max() ?? 0
        XCTAssertEqual(maxValue, 1.0, accuracy: 0.0001)        // peak bucket (3) / 3 → 1.0
        XCTAssertTrue(points.allSatisfy { $0.value >= 0 && $0.value <= 1 })
    }

    func test_normalizedWave_allZeroStaysZero() {
        let now = anchor
        let windowStart = date(8, anchor: now)
        let points = ActivityChartCard.normalizedWave(
            timestamps: [], windowStart: windowStart, now: now, bucketSize: 5 * 60, maxCount: 0)
        XCTAssertFalse(points.isEmpty)                          // dense buckets still emitted
        XCTAssertTrue(points.allSatisfy { $0.value == 0 })
    }

    func test_sharedMaxCount_isMaxBucketAcrossProviders() {
        let now = anchor
        let windowStart = date(8, anchor: now)
        // Provider A: 3 events in one bucket. Provider B: 1 event in one bucket.
        let a = [date(3.0, anchor: now), date(3.0, anchor: now), date(3.0, anchor: now)]
        let b = [date(5.0, anchor: now)]
        let shared = ActivityChartCard.sharedMaxCount(
            providerTimestamps: [a, b], windowStart: windowStart, now: now, bucketSize: 5 * 60)
        XCTAssertEqual(shared, 3)

        // On the shared scale, B's peak is 1/3, not 1.0.
        let bPoints = ActivityChartCard.normalizedWave(
            timestamps: b, windowStart: windowStart, now: now, bucketSize: 5 * 60, maxCount: shared)
        XCTAssertEqual(bPoints.map(\.value).max() ?? 0, 1.0 / 3.0, accuracy: 0.0001)
    }

    func test_usesMultiWave_threshold() {
        XCTAssertFalse(ActivityChartCard.usesMultiWave(activeCount: 0))
        XCTAssertFalse(ActivityChartCard.usesMultiWave(activeCount: 1))
        XCTAssertTrue(ActivityChartCard.usesMultiWave(activeCount: 2))
        XCTAssertTrue(ActivityChartCard.usesMultiWave(activeCount: 3))
    }

    // MARK: - tickInterval

    func testTickInterval_thresholds() {
        // ≤ 8h → 2h
        XCTAssertEqual(ActivityChartCard.tickInterval(window: 4 * 3600), 2 * 3600)
        XCTAssertEqual(ActivityChartCard.tickInterval(window: 8 * 3600), 2 * 3600)
        // 8h < w ≤ 16h → 4h
        XCTAssertEqual(ActivityChartCard.tickInterval(window: 12 * 3600), 4 * 3600)
        XCTAssertEqual(ActivityChartCard.tickInterval(window: 16 * 3600), 4 * 3600)
        // 16h < w ≤ 24h → 6h
        XCTAssertEqual(ActivityChartCard.tickInterval(window: 20 * 3600), 6 * 3600)
        XCTAssertEqual(ActivityChartCard.tickInterval(window: 24 * 3600), 6 * 3600)
    }

    // MARK: - hourMarks

    func testHourMarks_eightHourWindow() {
        XCTAssertEqual(
            ActivityChartCard.hourMarks(window: 8 * 3600),
            [-8, -6, -4, -2]
        )
    }

    func testHourMarks_twelveHourWindow() {
        // 12h window with 4h ticks → [-12, -8, -4]
        XCTAssertEqual(
            ActivityChartCard.hourMarks(window: 12 * 3600),
            [-12, -8, -4]
        )
    }

    func testHourMarks_twentyFourHourWindow() {
        // 24h window with 6h ticks → [-24, -18, -12, -6]
        XCTAssertEqual(
            ActivityChartCard.hourMarks(window: 24 * 3600),
            [-24, -18, -12, -6]
        )
    }
}
