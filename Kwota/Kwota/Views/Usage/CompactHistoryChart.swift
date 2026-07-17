//
//  CompactHistoryChart.swift
//  Kwota
//
//  The point of compact mode: session and week on ONE axis, so "is my week
//  draining faster than my session?" is answerable at a glance. Both lines
//  show REMAINING quota, matching the battery bars above — down means running
//  out, and a reset reads as a refill back to 100.
//
//  All series logic lives in CompactHistorySeries; this view only draws.
//

import SwiftUI
import Charts

struct CompactHistoryChart: View {
    let history: [UsageHistoryEntry]
    var now: Date = Date()

    static let sessionColor: Color = .green
    static let weekColor: Color = .blue

    var body: some View {
        let series = CompactHistorySeries.series(from: history, now: now)
        let start = now.addingTimeInterval(-CompactHistorySeries.defaultWindow)

        VStack(alignment: .leading, spacing: 6) {
            legend
            if series.session.isEmpty && series.week.isEmpty {
                Text("No history in the last 24 hours")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                chart(series: series, start: start)
            }
        }
    }

    private func chart(
        series: (session: [CompactHistorySeries.Point], week: [CompactHistorySeries.Point]),
        start: Date
    ) -> some View {
        Chart {
            // Week first so the busier session line draws on top of it.
            ForEach(series.week, id: \.self) { point in
                LineMark(
                    x: .value("Time", point.at),
                    y: .value("Remaining", point.remaining),
                    series: .value("Series", "week-\(point.segment)")
                )
                .foregroundStyle(Self.weekColor)
                .interpolationMethod(.stepEnd)
            }
            ForEach(series.session, id: \.self) { point in
                LineMark(
                    x: .value("Time", point.at),
                    y: .value("Remaining", point.remaining),
                    series: .value("Series", "session-\(point.segment)")
                )
                .foregroundStyle(Self.sessionColor)
                .interpolationMethod(.stepEnd)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: start...now)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) {
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .frame(height: 90)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(color: Self.sessionColor, text: "Session")
            legendItem(color: Self.weekColor, text: "Week")
            Spacer()
            Text("last 24h")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
