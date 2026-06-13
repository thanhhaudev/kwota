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
        case today = "Today", week = "7d", month = "30d", all = "All"
        var id: String { rawValue }
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

    private var sinceDay: String? { store.sinceDayKey(daysAgo: range.daysAgo) }

    private var modelRows: [(model: String, tokens: TokenBreakdown)] {
        store.totalsByModel(provider: .claude, sinceDay: sinceDay)
            .map { (model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens.billable > $1.tokens.billable }
    }

    var body: some View {
        // Reading store.revision forces re-render when the rollup changes.
        let _ = store.revision
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if modelRows.isEmpty {
                    Text("No usage recorded in this range yet.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else {
                    ForEach(modelRows, id: \.model) { row in
                        StatsModelCard(model: row.model, tokens: row.tokens)
                    }
                    StatsDailyChart(series: store.dailySeries(provider: .claude, sinceDay: sinceDay))
                        .frame(height: 160)
                        .padding(.top, 4)
                }
            }
            .padding(12)
        }
    }
}

/// One per-model totals card: billable vs cache-read.
private struct StatsModelCard: View {
    let model: String
    let tokens: TokenBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(StatsModelPalette.color(for: model)).frame(width: 8, height: 8)
                Text(StatsModelPalette.label(for: model)).font(.headline)
                Spacer()
                Text(StatsFormat.tokens(tokens.billable)).font(.headline).monospacedDigit()
            }
            HStack(spacing: 16) {
                metric("Input", tokens.input)
                metric("Output", tokens.output)
                metric("Cache read", tokens.cacheRead)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(StatsFormat.tokens(value)).font(.caption).monospacedDigit()
        }
    }
}

/// Compact token formatter ("12.3K", "1.2M").
enum StatsFormat {
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.1fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
}

/// Daily stacked bars: billable tokens per model per day, colored by model.
struct StatsDailyChart: View {
    let series: [(day: String, byModel: [String: TokenBreakdown])]

    private struct Bar: Identifiable {
        let id = UUID()
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
            .foregroundStyle(StatsModelPalette.color(for: bar.model))
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let n = value.as(Int.self) { Text(StatsFormat.tokens(n)) }
                }
            }
        }
    }
}
