//
//  ClaudeStatsDetailView.swift
//  Kwota
//

import SwiftUI
import Charts

struct ClaudeStatsDetailView: View {
    let store: StatsStore
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

    @State private var range: Range = .week
    @State private var showClearConfirm = false

    private var sinceDay: String? { store.sinceDayKey(daysAgo: range.daysAgo) }

    private var modelRows: [(model: String, tokens: TokenBreakdown)] {
        store.totalsByModel(provider: .claude, sinceDay: sinceDay)
            .map { (model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens.billable > $1.tokens.billable }
    }

    /// Provider has recorded usage in *some* range (all-time, range-independent).
    /// Distinguishes "brand new" from "selected range is empty".
    private var hasAnyData: Bool {
        store.total(provider: .claude, sinceDay: nil) != .zero
    }

    var body: some View {
        // Reading store.revision forces re-render when the rollup changes.
        let _ = store.revision
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                summaryCard
                dailyCard
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("Clear all Claude token stats?",
                            isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { store.clear(provider: .claude) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes recorded Claude token usage. It can't be undone.")
        }
    }

    // MARK: Cards

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            cardHeader
            if modelRows.isEmpty {
                Text("No usage recorded in this range yet.")  // replaced in Task 3
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ForEach(Array(modelRows.enumerated()), id: \.element.model) { idx, row in
                    if idx > 0 {
                        Rectangle().fill(Color.secondary.opacity(0.1))
                            .frame(height: 0.5)
                            .padding(.vertical, 2)
                    }
                    StatsModelRow(model: row.model, tokens: row.tokens)
                }
            }
        }
        .kwotaCard()
    }

    private var dailyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily usage")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(1.5)
                .textCase(.uppercase)
            StatsDailyChart(series: store.dailySeries(provider: .claude, sinceDay: sinceDay))
                .frame(height: 96)
        }
        .kwotaCard()
    }

    /// Range dropdown as the card title + overflow (⋯) Clear menu.
    private var cardHeader: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Range.allCases) { r in
                    Button(r.menuLabel) { range = r }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(range.menuLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Menu {
                Button("Clear Claude Stats…", role: .destructive) { showClearConfirm = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Claude stats options")
        }
        .padding(.bottom, 2)
    }
}

/// One per-model row: color dot + name + total billable on the primary line,
/// with an indented `In · Out · Cache` secondary line.
private struct StatsModelRow: View {
    let model: String
    let tokens: TokenBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(StatsModelPalette.color(for: model))
                    .frame(width: 8, height: 8)
                Text(StatsModelPalette.label(for: model))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(StatsFormat.tokens(tokens.billable))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                // Indent under the model name (8pt dot + 8pt gap).
                Color.clear.frame(width: 16, height: 0)
                subMetric("In", tokens.input)
                dot
                subMetric("Out", tokens.output)
                dot
                subMetric("Cache", tokens.cacheRead)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 3)
    }

    private var dot: some View {
        Text("·").font(.caption2).foregroundStyle(.tertiary)
    }

    private func subMetric(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(StatsFormat.tokens(value)).font(.caption2)
                .foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// Daily stacked bars: billable tokens per model per day, colored by model.
struct StatsDailyChart: View {
    let series: [(day: String, byModel: [String: TokenBreakdown])]

    private struct Bar: Identifiable {
        var id: String { "\(day)|\(model)" }
        let day: String
        let model: String
        let billable: Int
    }

    private var bars: [Bar] {
        series.flatMap { entry in
            entry.byModel.map { Bar(day: entry.day, model: $0.key, billable: $0.value.billable) }
        }
    }

    var body: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value("Day", String(bar.day.suffix(5))),   // "MM-dd"
                y: .value("Tokens", bar.billable)
            )
            .cornerRadius(2)
            .foregroundStyle(by: .value("Model", bar.model))
        }
        .chartLegend(.hidden)
        .chartForegroundStyleScale { (model: String) in StatsModelPalette.color(for: model) }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel {
                    if let n = value.as(Int.self) {
                        Text(StatsFormat.tokens(n)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let s = value.as(String.self) {
                        Text(s).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
