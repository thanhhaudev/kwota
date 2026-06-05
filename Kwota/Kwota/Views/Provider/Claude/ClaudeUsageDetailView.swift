//
//  ClaudeUsageDetailView.swift
//  Kwota
//
//  Claude-specific Usage tab body. Owns: Current Session card, Weekly Limit
//  card with optional merged per-model rows, and ExtraUsage row. Does NOT
//  own: profile header card, status banner, refresh button — those live in
//  the shell so they stay consistent across providers.
//

import SwiftUI

struct ClaudeUsageDetailView: View {
    let snapshot: UsageSnapshot
    let history: [UsageHistoryEntry]
    let isFreePlan: Bool

    @AppStorage(AppStorageKeys.displayChartShowAvg)      private var showAvg: Bool = true
    @AppStorage(AppStorageKeys.displayChartShowPaceHint) private var showPaceHint: Bool = true

    var body: some View {
        let charts = UsageTrendChart(
            snapshot: snapshot,
            history: history,
            showAvg: showAvg,
            showPaceHint: showPaceHint
        )

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Current Session")
                charts.card(for: .session)
                    .overlay { if isFreePlan { freeOverlay } }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Weekly Limit")
                charts.weeklyCard {
                    if hasPerModelData {
                        PerModelCard(
                            opus: effectiveOpus,
                            sonnet: effectiveSonnet,
                            omelette: effectiveOmelette
                        )
                    }
                }
                .overlay { if isFreePlan { freeOverlay } }
            }
            if let extra = snapshot.extra, extra.isEnabled {
                ExtraUsageRow(extra: extra)
            }
        }
    }

    private var effectiveOpus: UsageBucket? {
        snapshot.effectiveSevenDayOpus()
    }

    private var effectiveSonnet: UsageBucket? {
        snapshot.effectiveSevenDaySonnet()
    }

    private var effectiveOmelette: UsageBucket? {
        snapshot.effectiveSevenDayOmelette()
    }

    private var hasPerModelData: Bool {
        (effectiveOpus?.utilization != nil)
            || (effectiveSonnet?.utilization != nil)
            || (effectiveOmelette?.utilization != nil)
    }

    private var freeOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text("Not available on Free plan")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.primary)
                if let url = URL(string: "https://claude.ai/upgrade") {
                    Link("Upgrade", destination: url).font(.caption2)
                }
            }
            .multilineTextAlignment(.center)
            .padding(8)
        }
    }
}
