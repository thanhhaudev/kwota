//
//  CompactUsageView.swift
//  Kwota
//
//  Provider-agnostic compact Usage body: a glance-first "status list". Header,
//  then a session row and a weekly row rendered as CompactStatusRow (battery
//  meter + verdict tag), then the caller's extra rows (per-model / per-category).
//
//  It takes the provider's already-built `UsageTrendChartInput` rather than
//  `ProviderUsageSummary.primary` on purpose: providers put the RAW bucket in
//  `summary.primary` and nothing clamps it downstream, while the chart input is
//  built from the `effective…()` accessors that clamp a stale window to 0.
//  Feeding this view `summary.primary` would make compact claim 100% while the
//  normal chart says 0% for the same account, in the gap between a reset and the
//  server catching up.
//

import SwiftUI

struct CompactUsageView<ExtraRows: View>: View {
    let input: UsageTrendChartInput
    let history: [UsageHistoryEntry]
    var now: Date = Date()
    @ViewBuilder var extraRows: () -> ExtraRows

    var body: some View {
        let pace = CompactUsagePaceSeries.series(from: history, now: now)

        return VStack(alignment: .leading, spacing: 14) {
            header

            if let fiveHour = input.fiveHour {
                CompactStatusRow(
                    label: "Current session",
                    utilization: fiveHour.utilization,
                    resetsAt: fiveHour.resetsAt,
                    now: now,
                    tag: CompactUsageStatus.headlineTag(
                        utilization: fiveHour.utilization,
                        resetsAt: fiveHour.resetsAt,
                        latest: pace.session.last,
                        now: now
                    )
                )
            }
            if let sevenDay = input.sevenDay {
                CompactStatusRow(
                    label: "Weekly",
                    utilization: sevenDay.utilization,
                    resetsAt: sevenDay.resetsAt,
                    now: now,
                    tag: CompactUsageStatus.headlineTag(
                        utilization: sevenDay.utilization,
                        resetsAt: sevenDay.resetsAt,
                        latest: pace.week.last,
                        now: now
                    )
                )
            }
            if input.fiveHour == nil && input.sevenDay == nil {
                Text(input.hasRealData ? "No quota windows reported" : "Waiting for first fetch…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            extraRows()
        }
        .kwotaCard()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Usage")
                .font(.callout.weight(.semibold))
            Spacer()
            Text("% remaining")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

extension CompactUsageView where ExtraRows == EmptyView {
    init(input: UsageTrendChartInput, history: [UsageHistoryEntry], now: Date = Date()) {
        self.init(input: input, history: history, now: now, extraRows: { EmptyView() })
    }
}
