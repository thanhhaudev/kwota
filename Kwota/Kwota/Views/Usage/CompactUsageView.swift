//
//  CompactUsageView.swift
//  Kwota
//
//  Provider-agnostic compact Usage body: session bar, weekly bar, caller's
//  extra rows (per-model / per-category), then the shared-axis history chart.
//
//  It takes the provider's already-built `UsageTrendChartInput` rather than
//  `ProviderUsageSummary.primary` on purpose: providers put the RAW bucket in
//  `summary.primary` and nothing clamps it downstream, while the chart input
//  is built from the `effective…()` accessors that clamp a stale window to 0.
//  Feeding this view `summary.primary` would make compact claim 100% while the
//  normal chart says 0% for the same account, in the gap between a reset and
//  the server catching up.
//

import SwiftUI

struct CompactUsageView<ExtraRows: View>: View {
    let input: UsageTrendChartInput
    let history: [UsageHistoryEntry]
    var now: Date = Date()
    @ViewBuilder var extraRows: () -> ExtraRows

    var body: some View {
        // spacing: 0 — see the type doc. Children own their padding.
        VStack(alignment: .leading, spacing: 0) {
            if let fiveHour = input.fiveHour {
                CompactQuotaBar(label: "Current session", bucket: fiveHour, now: now)
                    .padding(.bottom, 12)
            }
            if let sevenDay = input.sevenDay {
                CompactQuotaBar(label: "Weekly", bucket: sevenDay, now: now)
                    .padding(.bottom, 12)
            }
            if input.fiveHour == nil && input.sevenDay == nil {
                Text(input.hasRealData ? "No quota windows reported" : "Waiting for first fetch…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }

            extraRows()

            CompactHistoryChart(history: history, now: now)
                .padding(.top, 4)
        }
        .kwotaCard()
    }
}

extension CompactUsageView where ExtraRows == EmptyView {
    init(input: UsageTrendChartInput, history: [UsageHistoryEntry], now: Date = Date()) {
        self.init(input: input, history: history, now: now, extraRows: { EmptyView() })
    }
}
