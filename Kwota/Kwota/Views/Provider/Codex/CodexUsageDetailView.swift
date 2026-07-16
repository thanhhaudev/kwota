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
        let windows = snapshot.classifiedWindows
        let visibility = Self.cardVisibility(
            hasSession: windows.session != nil,
            hasWeekly: windows.weekly != nil,
            isFreePlan: isFreePlan
        )

        VStack(alignment: .leading, spacing: 10) {
            if visibility.showSession {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Current Session")
                    charts.card(for: .session)
                }
            }

            if visibility.showWeekly {
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

    /// Which usage cards to render, given which windows the server actually
    /// sent. Pure + static so the "adapt to whichever windows exist" rule is
    /// unit-testable without a SwiftUI host.
    ///
    /// - Weekly card: only when a weekly window exists AND the plan exposes a
    ///   meaningful weekly limit (free tier's weekly is not — see type docs).
    /// - Session card: whenever a 5-hour window exists. When NEITHER window is
    ///   present — e.g. the intermittent `rate_limit: null` 200 — the session
    ///   card still shows as the "waiting for data" placeholder so the tab is
    ///   never blank; it degrades to skeleton bars exactly like a first fetch.
    ///   It is hidden only in the one case that would otherwise mislead: a
    ///   weekly window present with no session window (today's OpenAI shape),
    ///   where an empty 5-hour card would imply a burst limit that no longer
    ///   exists.
    static func cardVisibility(
        hasSession: Bool,
        hasWeekly: Bool,
        isFreePlan: Bool
    ) -> (showSession: Bool, showWeekly: Bool) {
        let showWeekly = hasWeekly && !isFreePlan
        let showSession = hasSession || !hasWeekly
        return (showSession: showSession, showWeekly: showWeekly)
    }

    private var chartInput: UsageTrendChartInput {
        // Classify by window duration, not slot (see
        // CodexUsageSnapshot.classifiedWindows). UsageBucket.utilization is
        // 0-100 across the app (Claude pipeline + UsageTrendChart formatter
        // both assume 0-100). Codex's used_percent already matches, so don't
        // normalize — earlier divide-by-100 left every value at < 1,
        // displaying "0% used" on real 4% / 13% data.
        let windows = snapshot.classifiedWindows
        return UsageTrendChartInput(
            fiveHour: windows.session.map {
                UsageBucket(utilization: $0.usedPercent, resetsAt: $0.resetAt)
            },
            sevenDay: windows.weekly.map {
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
