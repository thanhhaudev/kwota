//
//  UsageTrendChartFooterTests.swift
//  KwotaTests
//
//  Pure-logic tests for the chart's footer helpers — paceHint and
//  velocityFootnote — exercising the boundary cases we know are
//  user-visible (100%, near-100%, pace deadband).
//

import XCTest
@testable import Kwota

final class UsageTrendChartFooterTests: XCTestCase {
    // MARK: - paceHint

    func testPaceHintReturnsNilWhenLatestIsAt100() {
        // At 100% the comparison is meaningless and the footer would
        // otherwise read "on pace · typical 99%" because |100 - 99| < 5.
        XCTAssertNil(
            UsageTrendChart.paceHint(latest: 100, historicalAverage: 99)
        )
    }

    func testPaceHintReturnsNilWhenLatestIsAbove100() {
        // Defensive — utilization is clamped to 100 elsewhere, but a
        // future code path could produce 100.5 from rounding, and the
        // hint should still suppress.
        XCTAssertNil(
            UsageTrendChart.paceHint(latest: 100.5, historicalAverage: 99)
        )
    }

    func testPaceHintOnPaceWithinDeadband() {
        XCTAssertEqual(
            UsageTrendChart.paceHint(latest: 50, historicalAverage: 47),
            "on pace · typical 47%"
        )
    }

    func testPaceHintAboveTypical() {
        XCTAssertEqual(
            UsageTrendChart.paceHint(latest: 70, historicalAverage: 47),
            "above typical 47% · heavy"
        )
    }

    func testPaceHintBelowTypical() {
        XCTAssertEqual(
            UsageTrendChart.paceHint(latest: 30, historicalAverage: 47),
            "below typical 47%"
        )
    }

    func testPaceHintReturnsNilWhenInputsMissing() {
        XCTAssertNil(UsageTrendChart.paceHint(latest: nil, historicalAverage: 47))
        XCTAssertNil(UsageTrendChart.paceHint(latest: 50, historicalAverage: nil))
    }

    // MARK: - velocityFootnote

    func testVelocityFootnoteReturnsNilWhenLatestIsAt100() {
        // remaining = 0 → currently produces "≈ 0m to limit" which is noise.
        let entries: [UsageTrendChart.Entry] = [
            .init(at: Date().addingTimeInterval(-7200), value: 80),
            .init(at: Date().addingTimeInterval(-3600), value: 90),
            .init(at: Date(), value: 100),
        ]
        let bucket = UsageBucket(
            utilization: 100,
            resetsAt: Date().addingTimeInterval(3600)
        )
        XCTAssertNil(UsageTrendChart.velocityFootnote(realEntries: entries, bucket: bucket))
    }

    func testVelocityFootnoteReturnsETAUnder100() {
        // 60 → 75 → 90 (15%/h pace), latest 90, 10% remaining → ~40m to limit,
        // and the bucket resets in 2h, so the footer should fire.
        let entries: [UsageTrendChart.Entry] = [
            .init(at: Date().addingTimeInterval(-7200), value: 60),
            .init(at: Date().addingTimeInterval(-3600), value: 75),
            .init(at: Date(), value: 90),
        ]
        let bucket = UsageBucket(
            utilization: 90,
            resetsAt: Date().addingTimeInterval(7200)
        )
        let footer = UsageTrendChart.velocityFootnote(realEntries: entries, bucket: bucket)
        XCTAssertNotNil(footer)
        XCTAssertTrue(footer?.hasPrefix("≈ ") == true)
        XCTAssertTrue(footer?.hasSuffix(" to limit") == true)
    }

    func testVelocityFootnoteReturnsNilWhenETAExceedsResetWindow() {
        // 0.6%/h pace × 50% remaining ≈ 83h, but reset is in 2h.
        let entries: [UsageTrendChart.Entry] = [
            .init(at: Date().addingTimeInterval(-7200), value: 49.0),
            .init(at: Date().addingTimeInterval(-3600), value: 49.6),
            .init(at: Date(), value: 50.2),
        ]
        let bucket = UsageBucket(
            utilization: 50.2,
            resetsAt: Date().addingTimeInterval(7200)
        )
        XCTAssertNil(
            UsageTrendChart.velocityFootnote(realEntries: entries, bucket: bucket)
        )
    }

    // MARK: - effective-bucket clamp

    func testTrailingEntryClampedAt0WhenBucketReset() {
        // The helper is small; expose it as a static method for testing.
        let entries: [UsageTrendChart.Entry] = [
            .init(at: Date().addingTimeInterval(-7200), value: 70),
            .init(at: Date().addingTimeInterval(-3600), value: 85),
            .init(at: Date(), value: 90),
        ]
        let clamped = UsageTrendChart.applyTrailingResetClamp(
            entries: entries,
            effectiveUtilization: 0
        )
        XCTAssertEqual(clamped.count, 3)
        XCTAssertEqual(clamped[0].value, 70)
        XCTAssertEqual(clamped[1].value, 85)
        XCTAssertEqual(clamped[2].value, 0, "trailing entry should drop to 0 when bucket clamped")
    }

    func testTrailingEntryUnchangedWhenBucketActive() {
        let entries: [UsageTrendChart.Entry] = [
            .init(at: Date().addingTimeInterval(-3600), value: 50),
            .init(at: Date(), value: 60),
        ]
        let clamped = UsageTrendChart.applyTrailingResetClamp(
            entries: entries,
            effectiveUtilization: 60
        )
        XCTAssertEqual(clamped.last?.value, 60)
    }

    func testApplyTrailingResetClampHandlesEmptyArray() {
        let clamped = UsageTrendChart.applyTrailingResetClamp(
            entries: [],
            effectiveUtilization: 0
        )
        XCTAssertTrue(clamped.isEmpty)
    }

    func testApplyTrailingResetClampNoOpWhenEffectiveIsNil() {
        // nil utilization (e.g. the API didn't return the header) should not
        // overwrite the LOCF value — we only clamp when we *know* the
        // window has reset.
        let entries: [UsageTrendChart.Entry] = [
            .init(at: Date(), value: 80),
        ]
        let clamped = UsageTrendChart.applyTrailingResetClamp(
            entries: entries,
            effectiveUtilization: nil
        )
        XCTAssertEqual(clamped.last?.value, 80)
    }

    // MARK: - Cross-piece invariants

    func testSessionEntriesClampsTrailingBarWhenBucketReset() {
        // Snapshot whose 5h window has reset (resetsAt < now), so
        // effectiveFiveHour() clamps utilization to 0. History contains a
        // pre-reset 90% sample. The trailing bar from sessionEntries(...)
        // must drop to 0, agreeing with the footer's "0% remaining" string.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = UsageSnapshot(
            fiveHour: UsageBucket(utilization: 90, resetsAt: now.addingTimeInterval(-60)),
            sevenDay: UsageBucket(utilization: 30, resetsAt: now.addingTimeInterval(86_400))
        )
        let history: [UsageHistoryEntry] = [
            UsageHistoryEntry(at: now.addingTimeInterval(-3600), fiveHour: 90, sevenDay: 30)
        ]
        let entries = UsageTrendChart.sessionEntries(
            snapshot: snapshot,
            history: history,
            now: now
        )
        XCTAssertFalse(entries.isEmpty, "sessionEntries should produce at least one bar")
        XCTAssertEqual(entries.last?.value, 0, "trailing bar should clamp to 0 when bucket reset")
    }

    func testSaturatedSessionSuppressesPaceAndVelocityFooters() {
        // Snapshot at 100% with reset still in the future. Build entries
        // ending at 100, then assert both footer helpers suppress so the
        // chart reads only "0% remaining · ~Xh Ym left" without the noisy
        // "on pace" / "≈ 0m to limit" tail.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = UsageSnapshot(
            fiveHour: UsageBucket(utilization: 100, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 60, resetsAt: now.addingTimeInterval(86_400))
        )
        let history: [UsageHistoryEntry] = [
            UsageHistoryEntry(at: now.addingTimeInterval(-7200), fiveHour: 80, sevenDay: 50),
            UsageHistoryEntry(at: now.addingTimeInterval(-3600), fiveHour: 95, sevenDay: 55),
            UsageHistoryEntry(at: now,                            fiveHour: 100, sevenDay: 60),
        ]
        let entries = UsageTrendChart.sessionEntries(
            snapshot: snapshot,
            history: history,
            now: now
        )
        XCTAssertEqual(entries.last?.value, 100, "trailing bar should reflect saturated state")

        // paceHint suppresses on latest >= 100 regardless of avg.
        XCTAssertNil(
            UsageTrendChart.paceHint(
                latest: snapshot.fiveHour.utilization,
                historicalAverage: 95
            )
        )

        // velocityFootnote also suppresses on latest >= 100.
        XCTAssertNil(
            UsageTrendChart.velocityFootnote(
                realEntries: entries,
                bucket: snapshot.fiveHour
            )
        )
    }

    func testWeeklyEntriesClampsTodayBarWhenBucketResetOnSunday() {
        // Server-lag scenario, Sunday flavor: snapshot.sevenDay.resetsAt is
        // already in the past. Under the rolling-cycle anchor, this hits the
        // stale-API short-circuit (cycleStart = now), so today's bar is D1
        // rather than the trailing bar — but the invariant is the same as
        // the mid-week sibling: today's bar must clamp to 0.
        //
        // 2024-01-07 12:00 UTC is a Sunday in UTC and across the Americas /
        // Europe / most of Asia. NZDT/Chatham (UTC+13/+13:45) push it into
        // early Monday local; not realistic for our CI hosts.
        let now = Date(timeIntervalSince1970: 1_704_628_800) // Sun 2024-01-07 12:00 UTC
        let snapshot = UsageSnapshot(
            fiveHour: UsageBucket(utilization: 20, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 80, resetsAt: now.addingTimeInterval(-60))
        )
        let history: [UsageHistoryEntry] = [
            UsageHistoryEntry(at: now.addingTimeInterval(-86_400), fiveHour: 20, sevenDay: 80)
        ]
        let entries = UsageTrendChart.weeklyEntries(
            snapshot: snapshot,
            history: history,
            now: now
        )
        XCTAssertEqual(entries.count, 7, "weeklyEntries should always produce 7 day-bars")
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let todayEntry = entries.first(where: {
            cal.isDate($0.at, inSameDayAs: today) && !$0.isFuture
        })
        XCTAssertNotNil(todayEntry, "today's bar should be present and not marked future")
        XCTAssertEqual(todayEntry?.value, 0, "today's bar should clamp to 0 when weekly bucket reset")
    }

    func testWeeklyEntriesClampsTodayBarWhenBucketResetMidWeek() {
        // Mid-week reset: today is Wednesday; the trailing entry is a
        // future-Sunday placeholder, but the clamp must still fire on
        // today's bar (the last non-future entry).
        //
        // 2024-01-10 12:00 UTC is a Wednesday in UTC and across the
        // Americas / Europe / most of Asia. NZDT/Chatham (UTC+13/+13:45)
        // push it into early Thursday local; not realistic for our CI hosts.
        let now = Date(timeIntervalSince1970: 1_704_888_000) // Wed 2024-01-10 12:00 UTC
        let snapshot = UsageSnapshot(
            fiveHour: UsageBucket(utilization: 20, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 80, resetsAt: now.addingTimeInterval(-60))
        )
        let history: [UsageHistoryEntry] = [
            UsageHistoryEntry(at: now.addingTimeInterval(-86_400), fiveHour: 20, sevenDay: 80)
        ]
        let entries = UsageTrendChart.weeklyEntries(
            snapshot: snapshot,
            history: history,
            now: now
        )
        XCTAssertEqual(entries.count, 7, "weeklyEntries should always produce 7 day-bars")
        // Today's bar (Wednesday) — the last non-future entry — must clamp.
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let todayEntry = entries.first(where: {
            cal.isDate($0.at, inSameDayAs: today) && !$0.isFuture
        })
        XCTAssertNotNil(todayEntry, "expected today's entry to exist and not be future")
        XCTAssertEqual(todayEntry?.value, 0, "today's bar should clamp to 0 when weekly bucket reset")
        // Sunday (trailing) is still a future placeholder, value 0, isFuture true.
        XCTAssertEqual(entries.last?.value, 0)
        XCTAssertEqual(entries.last?.isFuture, true)
    }

    func testSessionEntriesCappedToFiveBarsWhenCurrentStartRoundsDown() {
        // When `now.minute < resetsAt.minute`, `currentSessionStart` lands on
        // `nowHour - 5h` (because `resetsAt - 5h` rounds DOWN to a full hour
        // earlier than `nowHour - 4h`). `hourlyBars` then emits 6 inclusive
        // hour buckets `[nowHour-5h … nowHour]`, but the chart's X-domain is
        // locked to a 5-slot frame `[nowHour-4h, nowHour+50min]`. SwiftUI
        // Charts partially renders the out-of-domain bar past the left edge,
        // bleeding past the popover. `sessionEntries` must cap at 5.
        //
        // 2024-01-09 13:30 UTC + resetsAt at 13:54 UTC ⇒ now.minute=30,
        // resetsAt.minute=54 ⇒ predicate fires.
        let now = Date(timeIntervalSince1970: 1_704_807_000)       // Tue 2024-01-09 13:30 UTC
        let resetsAt = Date(timeIntervalSince1970: 1_704_808_440)  // 13:54 UTC (~24m after now)
        let snapshot = UsageSnapshot(
            fiveHour: UsageBucket(utilization: 100, resetsAt: resetsAt),
            sevenDay: UsageBucket(utilization: 50, resetsAt: now.addingTimeInterval(86_400))
        )
        // Provide history so LOCF has anchors (otherwise bars are seeded 0).
        let history: [UsageHistoryEntry] = (0..<5).map { i in
            UsageHistoryEntry(
                at: now.addingTimeInterval(-Double(i) * 3600),
                fiveHour: Double(100 - i * 5),
                sevenDay: 50
            )
        }
        let entries = UsageTrendChart.sessionEntries(
            snapshot: snapshot,
            history: history,
            now: now
        )
        XCTAssertLessThanOrEqual(
            entries.count, 5,
            "sessionEntries must cap at 5 bars to fit the chart's locked 5-slot domain"
        )
    }

    func testCurrentSessionStartIgnoresSubMinuteResetJitter() {
        // The claude.ai usage API returns `five_hour.resets_at` with ~1s
        // jitter straddling an exact hour boundary (observed live:
        // 12:00:00 ↔ 11:59:59 across consecutive fetches). Because
        // `currentSessionStart` floors `resetsAt − 5h` to the hour, that 1s
        // wobble used to flip the session start by a full hour (07:00 ↔
        // 06:00), reshaping the Current Session chart on every refresh.
        // Minute-snapping must collapse both readings to the same start.
        let now = Date(timeIntervalSince1970: 1_780_042_050)            // 2026-05-29 08:07:30 UTC
        let onHour = Date(timeIntervalSince1970: 1_780_056_000)         // 12:00:00 UTC
        let oneSecEarlier = Date(timeIntervalSince1970: 1_780_055_999)  // 11:59:59 UTC

        func start(_ resetsAt: Date) -> Date {
            UsageTrendChart.currentSessionStart(
                snapshot: UsageSnapshot(
                    fiveHour: UsageBucket(utilization: 5, resetsAt: resetsAt),
                    sevenDay: UsageBucket(utilization: 50, resetsAt: now.addingTimeInterval(86_400))
                ),
                now: now
            )
        }

        XCTAssertEqual(
            start(onHour), start(oneSecEarlier),
            "1s jitter in resets_at across an hour boundary must not move the session start"
        )
        // Sanity: the start actually anchored off resetsAt (not clamped to
        // nowHour), so the equality above is not vacuously true.
        let cal = Calendar.current
        let nowHour = cal.dateInterval(of: .hour, for: now)!.start
        XCTAssertLessThan(start(onHour), nowHour)
    }

    // MARK: - formatResetCountdown (single absolute format)

    /// Structural check: every non-stale countdown should carry an
    /// abbreviated weekday + a time component (colon between hour and
    /// minute). Locale-resilient — the exact spelling of the weekday
    /// and the AM/PM marker varies across runners.
    private func assertWeekdayAndTime(
        _ result: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertTrue(result.hasPrefix("resets "), "expected 'resets ' prefix, got \(result)", file: file, line: line)
        XCTAssertTrue(result.contains(":"), "expected time separator, got \(result)", file: file, line: line)
    }

    func testResetCountdownFormat_whenOver24h_emitsAbsoluteTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let target = now.addingTimeInterval(3 * 86_400)  // 3 days ahead
        let result = UsageTrendChart.formatResetCountdown(until: target, now: now)
        assertWeekdayAndTime(result)
        XCTAssertFalse(result.contains("in "), "single format must not emit relative phrase: \(result)")
    }

    func testResetCountdownFormat_at14h_emitsAbsoluteTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let target = now.addingTimeInterval(14 * 3_600)
        let result = UsageTrendChart.formatResetCountdown(until: target, now: now)
        // 14h ago we'd have said "resets in 14h"; under the single absolute
        // format every delta gets the day-of-week + time treatment.
        assertWeekdayAndTime(result)
        XCTAssertFalse(result.contains("in "), "got \(result)")
    }

    func testResetCountdownFormat_atExactly24h_emitsAbsoluteTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let target = now.addingTimeInterval(24 * 3_600)
        assertWeekdayAndTime(UsageTrendChart.formatResetCountdown(until: target, now: now))
    }

    func testResetCountdownFormat_under1h_emitsAbsoluteTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let target = now.addingTimeInterval(23 * 60)
        let result = UsageTrendChart.formatResetCountdown(until: target, now: now)
        // No more "resets in 23m" branch — even close-to-now resets read
        // their absolute timestamp so the user keeps a single mental
        // model across the popover.
        assertWeekdayAndTime(result)
        XCTAssertFalse(result.contains("in "), "got \(result)")
    }

    func testResetCountdownFormat_atExactly1h_emitsAbsoluteTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let target = now.addingTimeInterval(3_600)
        assertWeekdayAndTime(UsageTrendChart.formatResetCountdown(until: target, now: now))
    }

    func testResetCountdownFormat_clampsZeroAndNegative() {
        // Past targets read "resets now" so a stale resetsAt doesn't
        // render a confusing past date. Used to be "resets in 0m" under
        // the hybrid format.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let target = now.addingTimeInterval(-300)
        XCTAssertEqual(
            UsageTrendChart.formatResetCountdown(until: target, now: now),
            "resets now"
        )
    }

    // MARK: - weeklyFootnoteText (static composition)

    func testWeeklyFootnoteEmbedsAbsoluteCountdown() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bucket = UsageBucket(
            utilization: 42,
            resetsAt: now.addingTimeInterval(14 * 3_600)  // 14h ahead
        )
        let text = UsageTrendChart.weeklyFootnoteText(
            bucket: bucket,
            hasRealData: true,
            isHeuristic: false,
            now: now
        )
        // "42% used · resets <Day> <H:MM AM/PM>". Locale-resilient: assert
        // the utilization prefix, the divider, and the absolute-format
        // markers (no "in ", colon time separator).
        XCTAssertTrue(text.hasPrefix("42% used · resets "), "got \(text)")
        XCTAssertTrue(text.contains(":"), "got \(text)")
        XCTAssertFalse(text.contains("in "), "single absolute format only: \(text)")
    }

    func testWeeklyFootnoteSwitchesToRemainingPastWarning() {
        // UsageLevel.warningThreshold is the green→amber line. Past it we
        // emit "X% remaining" instead of "Y% used".
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bucket = UsageBucket(
            utilization: 85,
            resetsAt: now.addingTimeInterval(3 * 86_400)
        )
        let text = UsageTrendChart.weeklyFootnoteText(
            bucket: bucket,
            hasRealData: true,
            isHeuristic: false,
            now: now
        )
        XCTAssertTrue(text.hasPrefix("15% remaining"), "got \(text)")
        XCTAssertTrue(text.contains("resets "), "got \(text)")
    }

    func testWeeklyFootnoteAppendsCalibratingWhenHeuristic() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bucket = UsageBucket(
            utilization: 42,
            resetsAt: now.addingTimeInterval(14 * 3_600)
        )
        let text = UsageTrendChart.weeklyFootnoteText(
            bucket: bucket,
            hasRealData: true,
            isHeuristic: true,
            now: now
        )
        // Structural: prefix carries usage + resets, suffix carries the
        // heuristic-cycle calibration marker. Time part is locale-formatted.
        XCTAssertTrue(text.hasPrefix("42% used · resets "), "got \(text)")
        XCTAssertTrue(text.contains(":"), "got \(text)")
        XCTAssertTrue(text.hasSuffix(" · calibrating"), "got \(text)")
    }

    func testWeeklyFootnoteReturnsWaitingWhenNoRealData() {
        let bucket = UsageBucket(utilization: nil, resetsAt: nil)
        let text = UsageTrendChart.weeklyFootnoteText(
            bucket: bucket,
            hasRealData: false,
            isHeuristic: false,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(text, "Waiting for first fetch…")
    }

    func testWeeklyFootnoteReturnsEmptyWhenBucketIsEmptyButFetchSucceeded() {
        // hasRealData == true but the bucket carries no utilization and
        // no resetsAt (a brief transient state where the API call landed
        // but the current bar's bucket hasn't populated). Both usage and
        // resets parts are nil; joined parts string is empty; the
        // instance `footnote(...)` caller then maps "" → nil and shows
        // nothing. Pin the contract so a future refactor of the helper
        // does not surface a stray "· calibrating" or "·" placeholder.
        let bucket = UsageBucket(utilization: nil, resetsAt: nil)
        let text = UsageTrendChart.weeklyFootnoteText(
            bucket: bucket,
            hasRealData: true,
            isHeuristic: false,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(text, "")
    }

    func testWeeklyFootnoteWaitingTextWinsOverCalibrating() {
        // hasRealData == false short-circuits to "Waiting for first
        // fetch…" — the isHeuristic flag must not append "· calibrating"
        // because there is no real anchor to calibrate against yet.
        let bucket = UsageBucket(utilization: nil, resetsAt: nil)
        let text = UsageTrendChart.weeklyFootnoteText(
            bucket: bucket,
            hasRealData: false,
            isHeuristic: true,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(text, "Waiting for first fetch…")
    }
}
