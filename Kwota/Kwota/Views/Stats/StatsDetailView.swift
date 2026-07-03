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

    private var modelRows: [(model: String, tokens: TokenBreakdown)] {
        // Today is derived from the LOCAL hourly rollup so the per-model cards
        // match the by-hour chart and the viewer's own clock. Wider ranges read
        // the UTC daily ledger.
        let byModel = range == .today
            ? hourlyTotalsByModel
            : store.totalsByModel(provider: provider, sinceDay: sinceDay)
        return byModel
            .map { (model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens.billable > $1.tokens.billable }
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
        if modelRows.isEmpty {
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
            } else if modelRows.isEmpty {
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

            HStack(spacing: 0) {
                miniMetric(icon: "arrow.down", value: tokens.input)
                Spacer(minLength: 6)
                miniMetric(icon: "arrow.up", value: tokens.output)
                Spacer(minLength: 6)
                miniMetric(icon: "bolt", value: tokens.cacheRead)
            }
            .help("Input \(StatsFormat.full(tokens.input))   ·   Output \(StatsFormat.full(tokens.output))   ·   Cache read \(StatsFormat.full(tokens.cacheRead))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Input \(tokens.input), Output \(tokens.output), Cache read \(tokens.cacheRead) tokens")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kwotaCard()
    }

    private func miniMetric(icon: String, value: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(StatsFormat.tokens(value))
                .font(.caption2).foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
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
        var id: String { "\(key)|\(model)" }
        let date: Date
        let key: String
        let model: String
        let billable: Int
    }

    private struct Total {
        let date: Date
        let key: String
        let total: Int
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

    private var bars: [Bar] {
        let order = orderedModels
        return points.flatMap { p in
            order.compactMap { model in
                p.byModel[model].map { Bar(date: p.date, key: p.key, model: model, billable: $0.billable) }
            }
        }
    }

    private var totals: [Total] {
        points.map { Total(date: $0.date, key: $0.key,
                           total: $0.byModel.values.reduce(0) { $0 + $1.billable }) }
    }

    private var average: Double {
        let t = totals.map(\.total)
        guard !t.isEmpty else { return 0 }
        return Double(t.reduce(0, +)) / Double(t.count)
    }

    private var dayTotal: Int { totals.reduce(0) { $0 + $1.total } }

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
    }

    /// Colors aligned 1:1 with `orderedLabels` (the scale range).
    private var orderedColors: [Color] {
        orderedModels.map { colors[$0] ?? .gray }
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

    @ViewBuilder
    private var readout: some View {
        HStack(spacing: 5) {
            if let selected {
                Text(selectedLabel(for: selected.date))
                    .font(.caption).fontWeight(.semibold)
                Text("·").foregroundStyle(.secondary)
                Text("\(StatsFormat.tokens(selected.total)) tokens")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else if mode == .hourly {
                Text("\(StatsFormat.tokens(dayTotal)) tokens today")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else if average > 0 {
                Text("Avg \(StatsFormat.tokens(Int(average.rounded())))/\(granularity.avgUnit)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }

    /// Label for the selected bucket: hourly → "3 PM"; daily → "Jun 13";
    /// weekly → "Jun 9 – 15"; monthly → "Jun 2026"; yearly → "2026".
    private func selectedLabel(for date: Date) -> String {
        // Same FormatStyle as the axis (`AxisValueLabel(format: .dateTime.hour())`)
        // so the hover readout follows the system 12/24-hour setting and can never
        // disagree with the axis labels.
        if mode == .hourly { return date.formatted(.dateTime.hour()) }
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

    /// Evenly-strided x-axis tick dates for daily mode, capped at `maxLabels` so
    /// labels never collide at popover width (`.automatic` treats desiredCount as
    /// advisory and overflows). Ticks start at the domain's lower bound and step
    /// by a whole number of granularity units. Day-tier strides above 4 round up
    /// to a multiple of 7 so consecutive labels land on the same weekday.
    static func xTicks(domain: ClosedRange<Date>,
                       granularity: StatsGranularity,
                       maxLabels: Int = 5,
                       calendar: Calendar = .current) -> [Date] {
        let unit = granularity.component
        let span = calendar.dateComponents([unit], from: domain.lowerBound,
                                           to: domain.upperBound).value(for: unit) ?? 0
        guard span > 0, maxLabels > 0 else { return [domain.lowerBound] }
        var step = max(1, Int((Double(span) / Double(maxLabels)).rounded(.up)))
        if granularity == .day, step > 4 {
            step += (7 - step % 7) % 7
        }
        var ticks: [Date] = []
        var tick = domain.lowerBound
        while tick < domain.upperBound, ticks.count < maxLabels {
            ticks.append(tick)
            guard let next = calendar.date(byAdding: unit, value: step, to: tick) else { break }
            tick = next
        }
        return ticks
    }

    private var chart: some View {
        Chart {
            ForEach(bars) { bar in
                BarMark(
                    x: .value("Time", bar.date, unit: unit),
                    y: .value("Tokens", bar.billable)
                )
                .cornerRadius(3)
                .foregroundStyle(by: .value("Model", StatsModelPalette.label(for: bar.model)))
                .opacity(isDimmed(bar) ? 0.18 : 1)
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
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.hour())
                }
            } else if granularity == .day, isWeekScale {
                // ≤8 days: single weekday letters, centered (too narrow to clip).
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            } else {
                // Right-anchored so the trailing-most label grows LEFT and never
                // overflows into the trailing value-axis gutter (no truncation),
                // while the value axis stays on the right.
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(anchor: .topTrailing) {
                        if let d = value.as(Date.self) {
                            Text(Self.xLabel(for: d, granularity: granularity))
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
