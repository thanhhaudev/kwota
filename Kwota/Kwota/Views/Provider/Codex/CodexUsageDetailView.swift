//
//  CodexUsageDetailView.swift
//  Kwota
//
//  Codex-specific Usage tab body. Owns: Current Session card, Weekly Limit
//  card with optional Code Review Weekly row, Credits row. Does NOT own:
//  profile header card, status banner, refresh button — those live in the
//  shell.
//
//  Free-plan handling: Codex's free tier still consumes the 5-hour primary
//  window but does not expose a meaningful weekly secondary, so the Session
//  card stays usable while the Weekly section is omitted entirely (header
//  included). Diverges from Claude, which locks both cards behind a
//  "Not available on Free plan" overlay.
//

import SwiftUI

struct CodexUsageDetailView: View {
    let snapshot: CodexUsageSnapshot
    let history: [UsageHistoryEntry]
    let isFreePlan: Bool

    @AppStorage(AppStorageKeys.displayChartShowAvg)      private var showAvg: Bool = true
    @AppStorage(AppStorageKeys.displayChartShowPaceHint) private var showPaceHint: Bool = true

    var body: some View {
        let charts = UsageTrendChart(
            input: chartInput,
            history: history,
            showAvg: showAvg,
            showPaceHint: showPaceHint
        )

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Current Session")
                charts.card(for: .session)
            }

            if !isFreePlan {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Weekly Limit")
                    charts.weeklyCard {
                        if hasPerCategoryData {
                            CodexPerCategoryCard(codeReviewWeekly: snapshot.codeReviewRateLimit)
                        }
                    }
                }
            }

            if let credits = snapshot.credits, credits.hasCredits == true {
                creditsRow(credits)
            }
        }
    }

    private var chartInput: UsageTrendChartInput {
        // UsageBucket.utilization is 0-100 across the app (Claude pipeline +
        // UsageTrendChart formatter both assume 0-100). Codex's used_percent
        // already matches, so don't normalize — earlier divide-by-100 left
        // every value at < 1, displaying "0% used" on real 4% / 13% data.
        UsageTrendChartInput(
            fiveHour: snapshot.rateLimit?.primaryWindow.map {
                UsageBucket(utilization: $0.usedPercent, resetsAt: $0.resetAt)
            },
            sevenDay: snapshot.rateLimit?.secondaryWindow.map {
                UsageBucket(utilization: $0.usedPercent, resetsAt: $0.resetAt)
            },
            hasRealData: snapshot.fetchedAt != .distantPast
        )
    }

    private var hasPerCategoryData: Bool {
        snapshot.codeReviewRateLimit?.usedPercent != nil
    }

    @ViewBuilder
    private func creditsRow(_ credits: CodexUsageSnapshot.Credits) -> some View {
        HStack {
            Text("Credits").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if credits.unlimited == true {
                Text("Unlimited").font(.caption.monospacedDigit())
            } else if let balance = credits.balance {
                Text(String(format: "$%.2f", balance)).font(.caption.monospacedDigit())
            } else {
                Text("—").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
