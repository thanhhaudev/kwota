//
//  StatsTimeChartHeadlessTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

/// The chart's estimated ("headless") band. Codex sessions run outside the TUI
/// leave no rollout, so only a running total reaches the ledger as
/// `TokenBreakdown.totalOnly`. That figure is the SAME unit as `billable`
/// (`(input − cached) + output` — the content newly added to a single-turn
/// session's context, which is exactly its final context size), and a turn is
/// only ever exact or total-only, never both. So the band stacks on top of the
/// measured model segments instead of replacing them, and totals count it.
final class StatsTimeChartHeadlessTests: XCTestCase {

    private func tb(input: Int = 0, output: Int = 0,
                    cacheRead: Int = 0, totalOnly: Int = 0) -> TokenBreakdown {
        TokenBreakdown(input: input, output: output, cacheRead: cacheRead, totalOnly: totalOnly)
    }

    // MARK: totals

    func test_billableTotal_sumsInputPlusOutput_excludingCacheAndTotalOnly() {
        let byModel = [
            "gpt-5.5": tb(input: 100, output: 20, cacheRead: 9_999, totalOnly: 500),
            "gpt-5.4": tb(input: 5, output: 5),
        ]
        XCTAssertEqual(StatsTimeChart.billableTotal(byModel), 130)
    }

    func test_headlessTotal_sumsTotalOnlyAcrossModels() {
        let byModel = [
            "gpt-5.5": tb(input: 100, output: 20, totalOnly: 400),
            "gpt-5.4": tb(totalOnly: 462),
        ]
        XCTAssertEqual(StatsTimeChart.headlessTotal(byModel), 862)
    }

    // MARK: barValues — stack order and band emission

    func test_mixedBucket_stacksOneBandOnTopOfTheMeasuredModels() {
        // The blind spot this design exists to close: a day with BOTH a normal
        // codex session and plugin sessions must show both, not drop the latter.
        let byModel = [
            "gpt-5.5": tb(input: 200_000, output: 15_483),   // billable 215,483
            "gpt-5.4": tb(totalOnly: 862_598),
        ]
        let bars = StatsTimeChart.barValues(for: byModel, order: ["gpt-5.5", "gpt-5.4"])
        XCTAssertEqual(bars.count, 3)
        // Measured models first…
        XCTAssertEqual(bars[0].model, "gpt-5.5")
        XCTAssertEqual(bars[0].value, 215_483)
        XCTAssertFalse(bars[0].isHeadless)
        XCTAssertEqual(bars[1].value, 0)          // gpt-5.4 has no billable
        XCTAssertFalse(bars[1].isHeadless)
        // …then exactly ONE estimated band on top, aggregating every model.
        XCTAssertTrue(bars[2].isHeadless)
        XCTAssertEqual(bars[2].value, 862_598)
        XCTAssertEqual(bars.filter(\.isHeadless).count, 1)
    }

    func test_measuredBucket_emitsNoBand() {
        let byModel = ["gpt-5.5": tb(input: 9_000_000, output: 900_000, cacheRead: 43_000_000)]
        let bars = StatsTimeChart.barValues(for: byModel, order: ["gpt-5.5"])
        XCTAssertEqual(bars.filter(\.isHeadless).count, 0)
        XCTAssertEqual(bars.map(\.value), [9_900_000])
    }

    func test_headlessOnlyBucket_emitsExactlyOneBand() {
        // The 2026-07-12 shape before the review session landed: plugin only.
        let byModel = ["gpt-5.5": tb(totalOnly: 782_889)]
        let bars = StatsTimeChart.barValues(for: byModel, order: ["gpt-5.5"])
        XCTAssertEqual(bars.filter(\.isHeadless).map(\.value), [782_889])
        XCTAssertEqual(bars.filter { !$0.isHeadless }.map(\.value), [0])
    }

    func test_emptyBucket_emitsNothing() {
        XCTAssertTrue(StatsTimeChart.barValues(for: [:], order: []).isEmpty)
        XCTAssertEqual(StatsTimeChart.barValues(for: ["gpt-5.5": .zero], order: ["gpt-5.5"])
                        .filter(\.isHeadless).count, 0)
    }

    func test_cacheReadOnlyBucket_emitsNoBand() {
        // Cache reads are in neither figure — they must not conjure a band.
        let byModel = ["gpt-5.5": tb(cacheRead: 50_000)]
        XCTAssertEqual(StatsTimeChart.barValues(for: byModel, order: ["gpt-5.5"])
                        .filter(\.isHeadless).count, 0)
    }

    func test_headlessLabel_marksEstimate() {
        // The band must read as an estimate, not a measured model.
        XCTAssertTrue(StatsTimeChart.headlessLabel.contains("est."))
    }

    // MARK: BY MODEL grid

    func test_modelRows_dropTotalOnlyModels_theyBelongToTheHeadlessCard() {
        // Total-only tokens are aggregated into the single "Headless (est.)"
        // card, mirroring the chart's single band — so a model with nothing
        // measured must not appear as its own card printing a misleading 0.
        let byModel = [
            "gpt-5.5": tb(input: 9_000_000, output: 900_000),
            "codex-auto-review": tb(totalOnly: 167_348),
        ]
        XCTAssertEqual(StatsDetailView.modelRows(from: byModel).map(\.model), ["gpt-5.5"])
        // …but the figure is still surfaced, by the headless card.
        XCTAssertEqual(StatsTimeChart.headlessTotal(byModel), 167_348)
    }

    func test_modelRows_allPluginRange_hasNoMeasuredCards() {
        let byModel = ["gpt-5.5": tb(totalOnly: 782_889)]
        XCTAssertTrue(StatsDetailView.modelRows(from: byModel).isEmpty)
        XCTAssertEqual(StatsTimeChart.headlessTotal(byModel), 782_889)
    }

    /// Emptiness must not be decided from `modelRows` alone: a range spent
    /// entirely in plugin sessions has NO measured rows, and gating on that sent
    /// the chart to its "no data" skeleton while sitting on real data — the very
    /// complaint this feature exists to fix.
    func test_allPluginRange_isNotEmpty() {
        let byModel = ["gpt-5.5": tb(totalOnly: 782_889)]
        XCTAssertTrue(StatsDetailView.modelRows(from: byModel).isEmpty)   // no measured rows…
        XCTAssertFalse(StatsDetailView.rangeIsEmpty(byModel))             // …but NOT empty
    }

    func test_genuinelyEmptyRange_isEmpty() {
        XCTAssertTrue(StatsDetailView.rangeIsEmpty([:]))
        XCTAssertTrue(StatsDetailView.rangeIsEmpty(["gpt-5.5": .zero]))
    }

    func test_measuredRange_isNotEmpty() {
        XCTAssertFalse(StatsDetailView.rangeIsEmpty(["gpt-5.5": tb(input: 1, output: 1)]))
    }

    func test_modelRows_cacheReadOnlyModel_keepsItsCard() {
        // Only total-only rows move to the headless card. A cache-read-only
        // model has none, so it keeps its (pre-existing) card.
        let byModel = [
            "gpt-5.5": tb(input: 100, output: 10),
            "gpt-5.4": tb(cacheRead: 50_000),
        ]
        XCTAssertEqual(Set(StatsDetailView.modelRows(from: byModel).map(\.model)),
                       ["gpt-5.5", "gpt-5.4"])
    }

    func test_modelRows_orderIsDeterministic() {
        // `byModel` is a Dictionary; equal sort keys must not shuffle per launch.
        let byModel = [
            "b-model": tb(input: 50, output: 0),
            "a-model": tb(input: 50, output: 0),
        ]
        let first = StatsDetailView.modelRows(from: byModel).map(\.model)
        for _ in 0..<20 {
            XCTAssertEqual(StatsDetailView.modelRows(from: byModel).map(\.model), first)
        }
    }
}
