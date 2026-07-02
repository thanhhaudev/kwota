//
//  PerModelCard.swift
//  Kwota
//
//  Stacked per-model utilization rows. Each row is rendered only when the
//  corresponding bucket is non-nil — matches Anthropic's claude.ai settings
//  page, which omits buckets the account doesn't have rather than rendering
//  empty placeholders. CLI-auth Messages API typically yields all-nil here,
//  so the caller gates the section on `hasPerModelData` to hide the whole
//  card in that case.
//

import SwiftUI
import Charts

struct PerModelCard: View {
    let opus: UsageBucket?
    let sonnet: UsageBucket?
    /// "Claude Design" — Anthropic's internal codename is `omelette`. Surface
    /// label diverges from field name on purpose; if the codename rotates, the
    /// decoder yields nil and the row vanishes. See `UsageSnapshot.sevenDayOmelette`.
    let omelette: UsageBucket?
    /// "Fable only" — sourced from the API's `limits[]` weekly_scoped entry
    /// (see `UsageSnapshot.sevenDayFable`). Pink matches the pinned family
    /// color in `StatsModelPalette` so the model reads consistently across
    /// the Usage and Stats tabs.
    let fable: UsageBucket?

    private let opusColor: Color = .blue
    private let sonnetColor: Color = .orange
    private let omeletteColor: Color = .purple
    private let fableColor: Color = .pink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let opus {
                row(label: "Opus", value: opus.utilization, color: opusColor)
            }
            if let sonnet {
                row(label: "Sonnet only", value: sonnet.utilization, color: sonnetColor)
            }
            if let fable {
                row(label: "Fable only", value: fable.utilization, color: fableColor)
            }
            if let omelette {
                row(label: "Claude Design", value: omelette.utilization, color: omeletteColor)
            }
        }
    }

    @ViewBuilder
    private func row(label: String, value: Double?, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            // Battery view: bar shows remaining (= 100 − utilization),
            // trailing percent matches direction. Bar full + "100%" =
            // healthy, bar small + "5%" = near the cap.
            bar(value: value.map { 100 - $0 } ?? 0, color: color, dimmed: value == nil)
                .frame(height: 8)
            Text(value.map { "\(Int(100 - $0))%" } ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(value == nil ? .secondary : .primary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func bar(value: Double, color: Color, dimmed: Bool) -> some View {
        Chart {
            BarMark(
                xStart: .value("Start", 0),
                xEnd:   .value("End", value),
                y:      .value("Track", "")
            )
            .foregroundStyle(dimmed ? Color.secondary.gradient : color.gradient)
            .cornerRadius(4)
        }
        .chartXScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plotArea in
            plotArea
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(4)
        }
    }
}
