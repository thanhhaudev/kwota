//
//  StatsTimeChartHeadlessTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

/// `StatsTimeChart`'s headless-bucket classification. A bucket is "headless
/// only" when Codex reported a running total but no per-type breakdown — the
/// signature of a non-TUI/plugin session. Such buckets render as a single faint
/// "Headless (est.)" band summing the total-only tokens; buckets with any
/// billable render normally and their total-only tokens are ignored, so the two
/// figures never mix units in one bar. Pure functions — no view instantiation.
final class StatsTimeChartHeadlessTests: XCTestCase {

    private func tb(input: Int = 0, output: Int = 0,
                    cacheRead: Int = 0, totalOnly: Int = 0) -> TokenBreakdown {
        TokenBreakdown(input: input, output: output, cacheRead: cacheRead, totalOnly: totalOnly)
    }

    // MARK: billableTotal / headlessTotal

    func test_billableTotal_sumsInputPlusOutputAcrossModels() {
        let byModel = [
            "gpt-5.5": tb(input: 100, output: 20, cacheRead: 9_999, totalOnly: 500),
            "gpt-5.4": tb(input: 5, output: 5),
        ]
        // cacheRead and totalOnly are excluded from billable.
        XCTAssertEqual(StatsTimeChart.billableTotal(byModel), 130)
    }

    func test_headlessTotal_sumsTotalOnlyAcrossModels() {
        let byModel = [
            "gpt-5.5": tb(input: 100, output: 20, totalOnly: 400),
            "gpt-5.4": tb(totalOnly: 462),
        ]
        XCTAssertEqual(StatsTimeChart.headlessTotal(byModel), 862)
    }

    // MARK: isHeadlessOnly

    func test_isHeadlessOnly_trueWhenNoBillableButTotalOnly() {
        // The 2026-07-12 shape: plugin-only day, total-only tokens, zero split.
        let byModel = ["gpt-5.5": tb(totalOnly: 782_889)]
        XCTAssertTrue(StatsTimeChart.isHeadlessOnly(byModel))
    }

    func test_isHeadlessOnly_falseWhenAnyBillable_evenWithTotalOnly() {
        // A real-usage day that also carries some total-only tokens
        // (e.g. codex-auto-review) must NOT be treated as headless — its
        // total-only tokens are ignored so the bar stays pure billable.
        let byModel = [
            "gpt-5.5": tb(input: 9_000_000, output: 900_000),
            "codex-auto-review": tb(totalOnly: 167_348),
        ]
        XCTAssertFalse(StatsTimeChart.isHeadlessOnly(byModel))
    }

    func test_isHeadlessOnly_falseWhenEmpty() {
        XCTAssertFalse(StatsTimeChart.isHeadlessOnly([:]))
        XCTAssertFalse(StatsTimeChart.isHeadlessOnly(["gpt-5.5": .zero]))
    }

    func test_isHeadlessOnly_falseWhenOnlyCacheRead() {
        // Cache-read without billable or total-only isn't a headless session.
        let byModel = ["gpt-5.5": tb(cacheRead: 50_000)]
        XCTAssertFalse(StatsTimeChart.isHeadlessOnly(byModel))
    }

    // MARK: realistic mixed range (last 7 days from the ledger)

    func test_mixedRange_onlyPluginDaysClassifyHeadless() {
        let days: [(String, [String: TokenBreakdown])] = [
            ("2026-07-08", ["gpt-5.5": tb(input: 1_700_000, output: 227_099),
                            "codex-auto-review": tb(totalOnly: 218_960)]),
            ("2026-07-10", ["gpt-5.5": tb(input: 7_400_000, output: 238_945)]),
            ("2026-07-11", ["gpt-5.5": tb(totalOnly: 1_502_269)]),
            ("2026-07-12", ["gpt-5.5": tb(totalOnly: 862_598)]),
        ]
        let headless = days.filter { StatsTimeChart.isHeadlessOnly($0.1) }.map(\.0)
        XCTAssertEqual(headless, ["2026-07-11", "2026-07-12"])
        // The plugin days surface their total-only sum as the bar height.
        XCTAssertEqual(StatsTimeChart.headlessTotal(days[2].1), 1_502_269)
        XCTAssertEqual(StatsTimeChart.headlessTotal(days[3].1), 862_598)
        // The real day's height stays its billable, ignoring its total-only.
        XCTAssertEqual(StatsTimeChart.billableTotal(days[0].1), 1_927_099)
    }

    func test_headlessLabel_marksEstimate() {
        // The label must read as an estimate, not a measured model, so viewers
        // don't sum it against billable bars.
        XCTAssertTrue(StatsTimeChart.headlessLabel.contains("est."))
    }
}
