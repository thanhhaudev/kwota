//
//  StatsDetailView.swift
//  Kwota
//

import SwiftUI
import Charts

struct StatsDetailView: View {
    let store: StatsStore
    let provider: ProviderID
    let profile: Profile

    enum Range: String, CaseIterable, Identifiable {
        case today, week, month, all
        var id: String { rawValue }
        /// Title shown in the dropdown and as the card title.
        var menuLabel: String {
            switch self {
            case .today: return "Today"
            case .week:  return "Last 7 days"
            case .month: return "Last 30 days"
            case .all:   return "All time"
            }
        }
        var daysAgo: Int? {
            switch self {
            case .today: return 0
            case .week:  return 6
            case .month: return 29
            case .all:   return nil
            }
        }
    }

    // Persisted so the popover/app reopens on the last-chosen range. `Range` is a
    // String-raw enum, which @AppStorage binds directly via its RawRepresentable
    // initializer. One global key — the picker preference is shared across providers.
    @AppStorage("statsRangeSelection") private var range: Range = .week

    private var sinceDay: String? { store.sinceDayKey(daysAgo: range.daysAgo) }

    /// Today is derived from the LOCAL hourly rollup so the per-model cards
    /// match the by-hour chart and the viewer's own clock. Wider ranges read
    /// the UTC daily ledger.
    private var rangeByModel: [String: TokenBreakdown] {
        range == .today
            ? hourlyTotalsByModel
            : store.totalsByModel(provider: provider, sinceDay: sinceDay)
    }

    private var modelRows: [(model: String, tokens: TokenBreakdown)] {
        Self.modelRows(from: rangeByModel)
    }

    /// The estimate shown by the grid's synthetic card — the same figure the
    /// chart stacks as its headless band, so the card is that band's color key.
    private var headlessTotal: Int { StatsTimeChart.headlessTotal(rangeByModel) }

    private var rangeIsEmpty: Bool { Self.rangeIsEmpty(rangeByModel) }

    /// Nothing to show: no measured model rows AND no estimate. One function, so
    /// the chart and the grid cannot disagree about emptiness — they already did
    /// once, and a range spent entirely in plugin sessions has no model rows at
    /// all, which sent the chart to its "no data" skeleton on top of real data.
    static func rangeIsEmpty(_ byModel: [String: TokenBreakdown]) -> Bool {
        modelRows(from: byModel).isEmpty && StatsTimeChart.headlessTotal(byModel) == 0
    }

    /// Measured rows for the BY MODEL grid: one card per model that has billable
    /// tokens. Total-only tokens are NOT per-model here — they're aggregated into
    /// the single "Headless (est.)" card, mirroring the chart's single band. So a
    /// model whose whole contribution is total-only has nothing measured to show
    /// and is dropped, rather than printing a misleading `0`.
    ///
    /// Ties break on model id: `byModel` is a Dictionary, so equal sort keys
    /// would otherwise shuffle the cards between launches.
    static func modelRows(from byModel: [String: TokenBreakdown])
        -> [(model: String, tokens: TokenBreakdown)] {
        byModel
            .map { (model: $0.key, tokens: $0.value) }
            .filter { row in
                guard row.tokens != .zero else { return false }   // nothing to show at all
                // Total-only tokens live on the headless card, not per model.
                return !(row.tokens.billable == 0 && row.tokens.totalOnly > 0)
            }
            .sorted { ($0.tokens.billable, $1.model) > ($1.tokens.billable, $0.model) }
    }

    /// Distinct color per model, shared by the chart and the per-model cards so
    /// a model's color matches across both. Built from the provider's *all-time*
    /// model set (not the range-filtered one) so a model keeps the same color
    /// when you switch ranges; the union with the visible rows covers any
    /// today-only model not yet in the all-time daily ledger.
    private var modelColors: [String: Color] {
        var models = Set(store.totalsByModel(provider: provider, sinceDay: nil).keys)
        models.formUnion(modelRows.map(\.model))
        return StatsModelPalette.colorMap(for: Array(models))
    }

    /// Per-model totals for the local "today" summed from the hourly rollup.
    private var hourlyTotalsByModel: [String: TokenBreakdown] {
        var out: [String: TokenBreakdown] = [:]
        for entry in store.hourlySeries(provider: provider, dayKey: store.currentDayKey()) {
            for (model, tokens) in entry.byModel {
                out[model] = (out[model] ?? .zero) + tokens
            }
        }
        return out
    }

    /// Provider has recorded usage in *some* range (all-time, range-independent).
    /// Distinguishes "brand new" from "selected range is empty".
    private var hasAnyData: Bool {
        store.total(provider: provider, sinceDay: nil) != .zero
    }

    /// Two equal columns for the per-model mini-card grid. Two (not three) so a
    /// card is wide enough to show the `↓ ↑ ⚡` breakdown on one row.
    private let gridColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        // Reading store.revision forces re-render when the rollup changes.
        let _ = store.revision
        Group {
            if !hasAnyData {
                ContentUnavailableView {
                    Label("No Token Usage Yet", systemImage: "chart.bar.xaxis")
                } description: {
                    Text("Token usage will appear here as you work with \(provider.displayName). Stats are kept until you clear them.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 0) {
                            // The range picker doubles as this section's header.
                            rangeMenu
                                .padding(.leading, 4)
                                .padding(.bottom, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            dailyCard
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            SectionHeader(title: "By Model")
                            summaryCard
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Cards

    @ViewBuilder
    private var summaryCard: some View {
        if rangeIsEmpty {
            VStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.title2).foregroundStyle(.secondary)
                Text("No usage in \(range.menuLabel.lowercased())")
                    .font(.callout).fontWeight(.semibold)
                Text("Try a wider range, or come back after using \(provider.displayName).")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .kwotaCard()
        } else {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                ForEach(modelRows, id: \.model) { row in
                    StatsModelMiniCard(model: row.model, tokens: row.tokens,
                                       color: modelColors[row.model] ?? .gray)
                }
                // Trails the measured models, mirroring the band's position on
                // top of the stack — and doubles as that band's color key.
                if headlessTotal > 0 {
                    StatsHeadlessMiniCard(tokens: headlessTotal)
                }
            }
        }
    }

    private var dailyCard: some View {
        Group {
            // Today routes by its own hourly points before the generic empty
            // check: `modelRows` for today is the hourly rollup, so an empty
            // today would otherwise fall into the weekly-style skeleton instead
            // of the dedicated "hourly starts going forward" note.
            if range == .today {
                if hourlyPoints.isEmpty {
                    hourlyCollectingNote
                } else {
                    StatsTimeChart(points: hourlyPoints, mode: .hourly, colors: modelColors)
                }
            } else if rangeIsEmpty {
                StatsDailySkeletonChart().frame(height: 96)
            } else {
                let series = store.chartSeries(provider: provider, daysAgo: range.daysAgo)
                StatsTimeChart(points: dailyPoints(from: series.points),
                               mode: .daily, granularity: series.granularity, colors: modelColors)
            }
        }
        .kwotaCard()
    }

    /// Today has daily totals but no hourly buckets yet — hourly capture only
    /// starts going forward (already-read events can't be re-bucketed).
    private var hourlyCollectingNote: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.badge")
                .font(.title3).foregroundStyle(.secondary)
            Text("Hourly breakdown starts from your next \(provider.displayName) activity today.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).frame(height: 96)
    }

    private func dailyPoints(from series: [(day: String, byModel: [String: TokenBreakdown])])
        -> [StatsTimeChart.Point] {
        series.compactMap { e in
            guard let (y, m, d) = StatsTimeChart.parseDayKey(e.day),
                  let date = StatsTimeChart.date(year: y, month: m, day: d) else { return nil }
            return .init(date: date, key: e.day, byModel: e.byModel)
        }
    }

    private var hourlyPoints: [StatsTimeChart.Point] {
        let today = store.currentDayKey()
        guard let (y, m, d) = StatsTimeChart.parseDayKey(today) else { return [] }
        return store.hourlySeries(provider: provider, dayKey: today).compactMap { e in
            guard let date = StatsTimeChart.date(year: y, month: m, day: d, hour: e.hour) else { return nil }
            return .init(date: date, key: "\(today) \(e.hour)", byModel: e.byModel)
        }
    }

    /// Range dropdown rendered as the trailing control of the top section
    /// header. Scopes both the chart and the per-model grid. (Clearing stats
    /// now lives in Settings → Data & Storage.)
    private var rangeMenu: some View {
        Menu {
            ForEach(Range.allCases) { r in
                Button(r.menuLabel) { range = r }
            }
        } label: {
            HStack(spacing: 4) {
                Text(range.menuLabel)
                    .font(.system(size: 11, weight: .medium))   // match SectionHeader title
                    .tracking(1.5)
                    .textCase(.uppercase)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        // `.button` + `.plain` instead of `.borderlessButton`: the borderless
        // style injects its own leading indicator and re-tints the label, which
        // pushed the chevron left and overrode `.secondary`. Plain renders the
        // label verbatim — chevron stays trailing, muted color sticks.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// One per-model mini-card for the 3-column grid: color dot + name, a prominent
/// billable total, and a compact stacked `In / Out / Cache` breakdown. Uses the
/// shared `kwotaCard` chrome so it matches the rest of the popover.
private struct StatsModelMiniCard: View {
    let model: String
    let tokens: TokenBreakdown
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(StatsModelPalette.label(for: model))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(StatsFormat.tokens(tokens.billable))
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            StatsMiniMetricRow(input: StatsFormat.tokens(tokens.input),
                               output: StatsFormat.tokens(tokens.output),
                               cache: StatsFormat.tokens(tokens.cacheRead))
                .help("Input \(StatsFormat.full(tokens.input))   ·   Output \(StatsFormat.full(tokens.output))   ·   Cache read \(StatsFormat.full(tokens.cacheRead))")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Input \(tokens.input), Output \(tokens.output), Cache read \(tokens.cacheRead) tokens")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kwotaCard()
    }
}

/// The `↓ ↑ ⚡` row shared by both mini-cards, so their geometry cannot drift.
/// Values arrive pre-formatted: the headless card has no breakdown to show and
/// passes the app's "no value" placeholder instead.
private struct StatsMiniMetricRow: View {
    let input: String
    let output: String
    let cache: String

    var body: some View {
        HStack(spacing: 0) {
            metric(icon: "arrow.down", text: input)
            Spacer(minLength: 6)
            metric(icon: "arrow.up", text: output)
            Spacer(minLength: 6)
            metric(icon: "bolt", text: cache)
        }
    }

    private func metric(icon: String, text: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption2).foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

/// Grid card for the chart's estimated band, and that band's color key.
///
/// Deliberately the SAME shape as a model card — dot, name, figure, `↓ ↑ ⚡` row
/// — because it belongs to the same grid. It differs only where the data does:
/// a muted dot matching the band, and the app's `—` placeholder in place of a
/// breakdown that does not exist. Set beside a model card, that reads on sight.
private struct StatsHeadlessMiniCard: View {
    let tokens: Int

    @State private var showingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.secondary)
                    .opacity(0.55)          // matches the band's own opacity
                    .frame(width: 7, height: 7)
                    .padding(.trailing, 2)
                Text(StatsTimeChart.headlessLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Click, not hover: `.help` waits out the system tooltip delay,
                // and the caveat is the whole point of the card. Same
                // Button + popover idiom as `SectionHeader`'s info affordance.
                Button {
                    showingInfo.toggle()
                } label: {
                    Image(systemName: showingInfo ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What \(StatsTimeChart.headlessLabel) means")
                .popover(isPresented: $showingInfo, arrowEdge: .top) {
                    Text(StatsTimeChart.headlessExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: 280, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            // "~" carries the caveat on the figure itself, so the number is never
            // quoted as if it were measured.
            Text("~\(StatsFormat.tokens(tokens))")
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            StatsMiniMetricRow(input: ProfileDetailFormatter.placeholder,
                               output: ProfileDetailFormatter.placeholder,
                               cache: ProfileDetailFormatter.placeholder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // No card-level `.help`: the ⓘ owns the explanation, and a second
        // hover-delayed copy of it over the whole card would just get in the way.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Headless, about \(tokens) tokens, estimated. No input, output or cache breakdown available.")
        .kwotaCard()
    }
}

/// Token chart in the Screen Time idiom: stacked bars by model on a real time
/// axis with tap-to-select highlighting. Serves both the multi-day view (one
/// bar per day + a dashed daily-average rule) and the Today view (one bar per
/// hour). The caller supplies pre-built points so date parsing stays out of the
/// chart.
struct StatsTimeChart: View {
    enum Mode { case daily, hourly }

    struct Point: Identifiable {
        let date: Date
        let key: String
        let byModel: [String: TokenBreakdown]
        var id: String { key }
    }

    let points: [Point]
    let mode: Mode
    /// Bucket size for daily mode (ignored for hourly). Drives the bar unit,
    /// x-axis domain/labels, avg unit, and the selected-bucket label.
    var granularity: StatsGranularity = .day
    /// Raw model id → color, supplied by the caller so the bars match the
    /// per-model cards (and stay distinct within this view).
    let colors: [String: Color]

    @State private var selectedDate: Date?

    private struct Bar: Identifiable {
        let id: String
        let date: Date
        let key: String
        let model: String   // real model id — drives color when !isHeadless
        let value: Int      // plotted height (billable, or total-only for headless)
        let isHeadless: Bool
    }

    private struct Total {
        let date: Date
        let key: String
        let billable: Int
        let headless: Int
        /// Bar height. The two summands are the same unit and cover disjoint
        /// turns, so they add (see `headlessTotal`).
        var value: Int { billable + headless }
    }

    /// Display name for the synthetic band carrying headless sessions — and the
    /// chart's series name for them. Kept bare: the estimate is signalled by the
    /// card's ⓘ (see `headlessExplanation`), the "~" on the figure, and the
    /// dashed breakdown, not by a suffix cluttering every label.
    static let headlessLabel = "Headless"

    /// The ⓘ tooltip. This is where the estimate is spelled out, so it has to
    /// say so plainly — nothing else on the card carries the caveat in words.
    static let headlessExplanation = """
        Estimated. Sessions run outside the TUI — via the plugin or app-server — leave no rollout, \
        so Codex reports only a running token total for them and never the input/output/cache split.
        """

    /// Σ billable (`input + output`) across a bucket's models.
    static func billableTotal(_ byModel: [String: TokenBreakdown]) -> Int {
        byModel.values.reduce(0) { $0 + $1.billable }
    }

    /// Σ total-only tokens across a bucket's models.
    ///
    /// Same unit as `billable`, so the two stack. `billable` is
    /// `(input − cached) + output` — i.e. the content ever *newly* added to the
    /// conversation — which for a single-turn session is exactly its final
    /// context size, and the context size is what Codex reports here. Measured
    /// on a session that emitted both signals: billable 122,335 vs total-only
    /// 121,311 (0.8% apart). Cache reads are in neither.
    ///
    /// A turn is only ever exact OR total-only (the trace reader retracts the
    /// estimate when exact usage arrives), so nothing is double-counted. Nor does
    /// a multi-turn thread re-count its earlier turns: the reader books each
    /// cumulative context reading against what the thread has already been
    /// credited, so only the new content lands here.
    static func headlessTotal(_ byModel: [String: TokenBreakdown]) -> Int {
        byModel.values.reduce(0) { $0 + $1.totalOnly }
    }

    /// Bars for one bucket, in stack order: the measured models (billable),
    /// then the single estimated band (total-only) on top.
    static func barValues(for byModel: [String: TokenBreakdown], order: [String])
        -> [(model: String, value: Int, isHeadless: Bool)] {
        var out = order.compactMap { model -> (model: String, value: Int, isHeadless: Bool)? in
            byModel[model].map { (model: model, value: $0.billable, isHeadless: false) }
        }
        let headless = headlessTotal(byModel)
        if headless > 0 {
            out.append((model: "", value: headless, isHeadless: true))
        }
        return out
    }

    /// "yyyy-MM-dd" → (year, month, day).
    static func parseDayKey(_ key: String) -> (Int, Int, Int)? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return (p[0], p[1], p[2])
    }

    /// Local wall-clock Date from explicit components, so Swift Charts bins and
    /// labels each bucket by the key's own numbers (the data is UTC; we render
    /// those numbers directly instead of re-projecting timezones).
    static func date(year: Int, month: Int, day: Int, hour: Int = 0) -> Date? {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
    }

    /// Models ordered by total billable across the whole visible range
    /// (descending), tie-broken by id so the order is fully deterministic —
    /// `byModel` is a Dictionary, so without this the stack order would shuffle
    /// every launch. Drives both the bar emission order and the foreground-style
    /// scale domain, keeping each color in the same band across every bucket
    /// (Screen Time style: the heaviest model anchors the baseline).
    private var orderedModels: [String] {
        var totals: [String: Int] = [:]
        for p in points {
            for (model, tb) in p.byModel { totals[model, default: 0] += tb.billable }
        }
        return totals.keys.sorted { (totals[$0]!, $1) > (totals[$1]!, $0) }
    }

    /// Any visible bucket carries an estimate — gates whether the synthetic
    /// "Headless (est.)" band joins the color scale.
    private var hasHeadless: Bool { points.contains { Self.headlessTotal($0.byModel) > 0 } }

    private var bars: [Bar] {
        let order = orderedModels
        return points.flatMap { p in
            Self.barValues(for: p.byModel, order: order).map { spec in
                Bar(id: "\(p.key)|\(spec.isHeadless ? "~headless" : spec.model)",
                    date: p.date, key: p.key, model: spec.model,
                    value: spec.value, isHeadless: spec.isHeadless)
            }
        }
    }

    /// Foreground-scale name for a bar: real models keep their palette label;
    /// headless bars share the single "Headless (est.)" band.
    private func foregroundLabel(_ bar: Bar) -> String {
        bar.isHeadless ? Self.headlessLabel : StatsModelPalette.label(for: bar.model)
    }

    private var totals: [Total] {
        points.map { Total(date: $0.date, key: $0.key,
                           billable: Self.billableTotal($0.byModel),
                           headless: Self.headlessTotal($0.byModel)) }
    }

    // Average and day totals count the estimate: it is the same unit as billable
    // and covers turns billable never saw, so excluding it would under-report a
    // day's real work — the whole reason headless sessions went missing before.
    private var average: Double {
        let t = totals.map(\.value)
        guard !t.isEmpty else { return 0 }
        return Double(t.reduce(0, +)) / Double(t.count)
    }

    private var dayTotal: Int { totals.reduce(0) { $0 + $1.value } }
    /// Some part of the visible total is estimated — the readout says so with a
    /// leading "~" rather than quoting an exact-looking figure.
    private var dayHasHeadless: Bool { totals.contains { $0.headless > 0 } }

    /// The bucket nearest the current selection point (nil when none selected).
    private var selected: Total? {
        guard let selectedDate else { return nil }
        return totals.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    /// Pretty labels in stack order (heaviest model first). Doubles as the
    /// foreground-style scale domain so segments stack in a stable order and the
    /// colors match the per-model cards below.
    private var orderedLabels: [String] {
        orderedModels.map { StatsModelPalette.label(for: $0) }
            + (hasHeadless ? [Self.headlessLabel] : [])
    }

    /// Colors aligned 1:1 with `orderedLabels` (the scale range). The headless
    /// band trails in muted secondary so it reads as an estimate, not a model.
    private var orderedColors: [Color] {
        orderedModels.map { colors[$0] ?? .gray }
            + (hasHeadless ? [Color.secondary] : [])
    }

    /// Faint the headless band (and dim non-selected bars) so an estimate never
    /// looks as solid as a measured model bar.
    private func opacity(for bar: Bar) -> Double {
        if isDimmed(bar) { return 0.18 }
        return bar.isHeadless ? 0.55 : 1
    }

    private func isDimmed(_ bar: Bar) -> Bool {
        guard let selected else { return false }
        return bar.key != selected.key
    }

    /// Weekday letters for a short daily range (Screen Time week style).
    private var isWeekScale: Bool { mode == .daily && totals.count <= 8 }
    /// The daily-average rule only belongs on the multi-day view.
    private var showsAverage: Bool { mode == .daily && average > 0 }
    private var unit: Calendar.Component { mode == .hourly ? .hour : granularity.component }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            readout
                .lineLimit(1)
                .frame(height: 18, alignment: .leading)   // fixed so selection doesn't resize the card
            chartWithScale.frame(height: 120)
        }
    }

    /// Hourly mode pins the x-axis to the full day so a single hour renders as a
    /// small bar at its position (Screen Time dayChart), not one giant bar.
    @ViewBuilder
    private var chartWithScale: some View {
        // A small symmetric `.plotDimension` inset so bars aren't flush to the
        // edges. The last date label no longer needs a wide trailing gap — it's
        // right-anchored (see chartXAxis) so it grows left, clearing the trailing
        // value-axis gutter on its own.
        if mode == .hourly, let domain = hourDomain {
            chart.chartXScale(domain: domain, range: .plotDimension(startPadding: 6, endPadding: 6))
        } else if mode == .daily, let domain = dayDomain {
            chart.chartXScale(domain: domain, range: .plotDimension(startPadding: 6, endPadding: 6))
        } else {
            chart
        }
    }

    private var hourDomain: ClosedRange<Date>? {
        guard mode == .hourly, let anchor = points.first?.date else { return nil }
        let start = Calendar.current.startOfDay(for: anchor)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return start...end
    }

    private var dayDomain: ClosedRange<Date>? {
        guard mode == .daily, let first = points.first?.date, let last = points.last?.date else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: first)
        // +1 of the granularity unit so the last bucket's bar isn't clipped.
        let end = cal.date(byAdding: granularity.component, value: 1, to: cal.startOfDay(for: last)) ?? last
        return start...end
    }

    /// Explicit ticks for the daily (non-week-scale) x-axis — bounded by
    /// xTicks' label budget so labels never truncate. Empty only in the
    /// defensive nil-domain case (the chart doesn't render without points).
    private var xTickValues: [XTick] {
        dayDomain.map { Self.xTicks(domain: $0, granularity: granularity) } ?? []
    }

    /// True when the tick at `date` carries a label. Matched by proximity, not
    /// equality — Charts round-trips axis values through its internal plottable
    /// representation, which may not preserve the Date bit-for-bit.
    private func isLabeledTick(_ date: Date) -> Bool {
        xTickValues.first { abs($0.date.timeIntervalSince(date)) < 1 }?.isLabeled ?? true
    }

    @ViewBuilder
    private var readout: some View {
        HStack(spacing: 5) {
            if let selected {
                Text(selectedLabel(for: selected.date))
                    .font(.caption).fontWeight(.semibold)
                Text("·").foregroundStyle(.secondary)
                // "~" whenever any of the figure is estimated, so an exact-looking
                // number is never quoted for a partly-estimated bucket.
                Text("\(selected.headless > 0 ? "~" : "")\(StatsFormat.tokens(selected.value)) tokens")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else if mode == .hourly {
                Text("\(dayHasHeadless ? "~" : "")\(StatsFormat.tokens(dayTotal)) tokens today")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else if average > 0 {
                Text("Avg \(StatsFormat.tokens(Int(average.rounded())))/\(granularity.avgUnit)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }

    /// Fixed 12-hour formatter ("9 AM") shared by the hourly axis and hover
    /// readout — deliberately NOT the system 12/24-hour setting: the app's UI
    /// is English and the Screen Time-style AM/PM reads better in the popover.
    /// One formatter for both call sites so they can never disagree.
    static let hourLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h a"
        return f
    }()

    /// Label for the selected bucket: hourly → "3 PM"; daily → "Jun 13";
    /// weekly → "Jun 9 – 15"; monthly → "Jun 2026"; yearly → "2026".
    private func selectedLabel(for date: Date) -> String {
        if mode == .hourly { return Self.hourLabelFormatter.string(from: date) }
        let f = DateFormatter()
        f.locale = .current
        switch granularity {
        case .day:
            f.dateFormat = "MMM d"; return f.string(from: date)
        case .week:
            f.dateFormat = "MMM d"
            let end = Calendar.current.date(byAdding: .day, value: 6, to: date) ?? date
            return "\(f.string(from: date)) – \(f.string(from: end))"
        case .month:
            f.dateFormat = "MMM yyyy"; return f.string(from: date)
        case .year:
            f.dateFormat = "yyyy"; return f.string(from: date)
        }
    }

    /// X-axis tick label per granularity, using LOCALE-ordered fields (the
    /// viewer's own day/month order, e.g. "11-05" vs "05-11") rather than a
    /// hard-coded pattern. day/week → month+day (week = its start day);
    /// month → abbreviated month + 2-digit year; year → full year.
    static func xLabel(for date: Date, granularity: StatsGranularity) -> String {
        switch granularity {
        case .day, .week: return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        case .month:      return date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        case .year:       return date.formatted(.dateTime.year())
        }
    }

    /// One x-axis tick for daily mode: a gridline position and whether it
    /// carries a label. Gridlines stay on the even stride all the way to the
    /// domain's oldest edge so the ranges between them look uniform; only the
    /// LABEL is suppressed when its boundary sits too close to the plot edge
    /// to render (`isLabeled == false`).
    struct XTick: Equatable {
        let date: Date
        let isLabeled: Bool
    }

    /// Evenly-strided x-axis ticks for daily mode, capped at `maxLabels` so
    /// labels never collide at popover width (`.automatic` treats desiredCount
    /// as advisory and overflows). Ticks are bucket-END boundaries: labels are
    /// right-anchored (they grow left, into the range they close), so each
    /// gridline marks where a range ends and its label names that range's last
    /// day (see the AxisValueLabel call site, which subtracts one day). Anchored
    /// at `upperBound` — the domain extends one unit past the newest bucket, so
    /// the final gridline sits at the plot's right edge labeled with the newest
    /// data — and strides backward; when the budget truncates, the OLDEST edge
    /// loses its ticks, never the newest. Day-tier strides above 4 round up to a
    /// multiple of 7 so consecutive labels land on the same weekday. The oldest
    /// boundary keeps its gridline but drops its label when less than half a
    /// stride separates it from the lower bound (the flooring remainder), where
    /// a right-anchored label would truncate against the plot edge.
    static func xTicks(domain: ClosedRange<Date>,
                       granularity: StatsGranularity,
                       maxLabels: Int = 5,
                       calendar: Calendar = .current) -> [XTick] {
        let unit = granularity.component
        let span = calendar.dateComponents([unit], from: domain.lowerBound,
                                           to: domain.upperBound).value(for: unit) ?? 0
        guard span > 0, maxLabels > 0 else { return [] }
        var step = max(1, Int((Double(span) / Double(maxLabels)).rounded(.up)))
        if granularity == .day, step > 4 {
            step += (7 - step % 7) % 7
        }
        // Count guard: dateComponents floors the span, which could otherwise
        // admit one tick beyond the budget.
        let halfStep = (step + 1) / 2
        var ticks: [XTick] = []
        var tick = domain.upperBound
        while ticks.count < maxLabels, tick > domain.lowerBound {
            let labeled = calendar.date(byAdding: unit, value: -halfStep, to: tick)
                .map { $0 >= domain.lowerBound } ?? false
            ticks.append(XTick(date: tick, isLabeled: labeled))
            guard let prev = calendar.date(byAdding: unit, value: -step, to: tick) else { break }
            tick = prev
        }
        return ticks.reversed()
    }

    private var chart: some View {
        Chart {
            ForEach(bars) { bar in
                BarMark(
                    x: .value("Time", bar.date, unit: unit),
                    y: .value("Tokens", bar.value)
                )
                .cornerRadius(3)
                .foregroundStyle(by: .value("Model", foregroundLabel(bar)))
                .opacity(opacity(for: bar))
            }
            if showsAverage {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 5]))
                    .annotation(position: .trailing, alignment: .leading) {
                        Text("avg").font(.caption2).foregroundStyle(.green)
                    }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartForegroundStyleScale(domain: orderedLabels, range: orderedColors)
        .chartLegend(.hidden)   // the BY MODEL grid below already shows the color key
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let n = value.as(Int.self) {
                        Text(StatsFormat.tokens(n)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            if mode == .hourly {
                AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let d = value.as(Date.self) {
                            Text(Self.hourLabelFormatter.string(from: d))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if granularity == .day, isWeekScale {
                // ≤8 days: single weekday letters, centered (too narrow to clip).
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            } else {
                // Explicit bounded ticks (xTicks): .automatic treats desiredCount
                // as advisory and overflows the popover width. Right-anchored so
                // the trailing-most label grows LEFT into the plot, clear of the
                // trailing value-axis gutter.
                AxisMarks(values: xTickValues.map(\.date)) { value in
                    AxisGridLine()
                    AxisTick()
                    // Each tick is a bucket-END boundary; the label names the
                    // day the range closes on (boundary − 1 day), and the
                    // trailing anchor tucks it left of the gridline, over the
                    // very range it describes — so a label never reads as
                    // belonging to the bars on the far side of its line.
                    // Unlabeled ticks (isLabeled == false) still draw their
                    // gridline so the ranges stay visually uniform.
                    AxisValueLabel(anchor: .topTrailing) {
                        if let d = value.as(Date.self), isLabeledTick(d),
                           let rangeEnd = Calendar.current.date(byAdding: .day, value: -1, to: d) {
                            Text(Self.xLabel(for: rangeEnd, granularity: granularity))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Empty-range placeholder: a chart frame of dashed gridlines + dashed-border
/// bars, communicating "chart shape" without faking values. Mirrors
/// `UsageTrendChart`'s skeleton idiom so users recognize it as a placeholder.
struct StatsDailySkeletonChart: View {
    private let fractions: [CGFloat] = [0.40, 0.60, 0.50, 0.80, 0.55, 0.70, 0.45]
    private let stroke = StrokeStyle(lineWidth: 0.8, dash: [3, 2])
    private let color = Color.secondary.opacity(0.35)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: 0) {
                    gridline
                    Spacer()
                    gridline
                    Spacer()
                    gridline
                }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(fractions.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(color, style: stroke)
                            .frame(maxWidth: .infinity)
                            .frame(height: max(8, geo.size.height * fractions[i]))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 4)
            }
        }
    }

    private var gridline: some View {
        StatsSkeletonRule().stroke(color, style: stroke).frame(height: 0.5)
    }
}

/// A single horizontal line through the view's vertical center, used for the
/// skeleton chart's dashed gridlines. Stroking a `Shape` paints the full line
/// inside the frame; a stroked `Rectangle` would center the stroke on the 0.5pt
/// border and clip to a hairline that can vanish at 1× scale.
private struct StatsSkeletonRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
