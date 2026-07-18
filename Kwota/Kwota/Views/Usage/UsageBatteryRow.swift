//
//  UsageBatteryRow.swift
//  Kwota
//
//  Shared battery-view row: a colored dot, a label, a bar showing REMAINING
//  quota (100 − utilization), and the matching percentage. Bar full + "100%"
//  = healthy, bar small + "5%" = near the cap.
//
//  Extracted from PerModelCard and CodexPerCategoryCard, which carried copies
//  of this row differing only in label width. Compact mode's per-model rows
//  are the third consumer.
//

import SwiftUI
import Charts

struct UsageBatteryRow: View {
    let label: String
    /// 0-100 utilization (USED) — the app-wide convention. The view renders
    /// `100 − utilization`. nil renders a dimmed empty bar and an em dash.
    let utilization: Double?
    let color: Color
    var labelWidth: CGFloat = 90
    var detail: String? = nil
    var isCompact: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(isCompact ? .callout : .caption)
                    .foregroundStyle(isCompact ? Color.primary : Color.secondary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: labelWidth, alignment: .leading)
            bar
                .frame(height: 8)
            Text(Self.remainingText(for: utilization))
                .font(isCompact ? .callout.monospacedDigit() : .caption.monospacedDigit())
                .foregroundStyle(utilization == nil ? .secondary : .primary)
                .frame(width: 36, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// Remaining quota as a 0-100 bar width. nil → 0 (dimmed empty track).
    /// Clamped because callers without a Charts scale (the compact headline
    /// bar) would otherwise overflow their track on out-of-range utilization.
    static func remainingWidth(for utilization: Double?) -> Double {
        guard let utilization else { return 0 }
        return max(0, min(100, 100 - utilization))
    }

    static func remainingText(for utilization: Double?) -> String {
        guard let utilization else { return "—" }
        return "\(Int(max(0, min(100, 100 - utilization))))%"
    }

    private var bar: some View {
        Chart {
            BarMark(
                xStart: .value("Start", 0),
                xEnd:   .value("End", Self.remainingWidth(for: utilization)),
                y:      .value("Track", "")
            )
            .foregroundStyle(utilization == nil ? Color.secondary.gradient : color.gradient)
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
