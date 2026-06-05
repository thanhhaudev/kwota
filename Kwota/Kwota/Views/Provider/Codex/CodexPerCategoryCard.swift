//
//  CodexPerCategoryCard.swift
//  Kwota
//
//  Vertical list of Codex-specific secondary categories (Code Review
//  Weekly; future Spark). Each row has the same bar/percentage layout as
//  Claude's PerModelCard. Hidden when all rows would be empty.
//

import SwiftUI
import Charts

struct CodexPerCategoryCard: View {
    let codeReviewWeekly: CodexUsageSnapshot.Window?

    private let codeReviewColor: Color = .green

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let codeReviewWeekly,
               codeReviewWeekly.usedPercent != nil {
                row(
                    label: "Code Review Weekly",
                    value: codeReviewWeekly.usedPercent,
                    color: codeReviewColor
                )
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
                .frame(width: 130, alignment: .leading)
            // Battery view: bar = remaining (= 100 − usedPercent),
            // trailing percent matches. See PerModelCard for the same
            // pattern across Claude / Codex / Antigravity.
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
