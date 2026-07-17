//
//  AntigravityUsageDetailView.swift
//  Kwota
//
//  Antigravity Usage tab body. A group picker (Gemini / Claude+GPT) with a
//  per-segment severity dot selects which group's quota to chart; below it the
//  standard UsageTrendChart Session(5h) + Weekly cards render that group's two
//  windows — same layout as the Claude/Codex tabs. The AI-credits / overage
//  row stays at the bottom. Data source: RetrieveUserQuotaSummary (the numbers
//  the Antigravity app itself shows), not the retired per-model quotaInfo.
//

import SwiftUI

/// Pure view logic, factored out so selection/dot/chart-input rules are unit
/// testable without a SwiftUI host.
enum AntigravityUsageGroupLogic {
    static func defaultSelection(quota: AntigravityQuotaSummary) -> String? {
        quota.bindingGroupKey ?? quota.groups.first?.key
    }

    static func resolvedKey(selected: String?, quota: AntigravityQuotaSummary) -> String? {
        if let selected, quota.groups.contains(where: { $0.key == selected }) { return selected }
        return defaultSelection(quota: quota)
    }

    static func dotColor(for group: AntigravityQuotaSummary.Group) -> Color {
        UsageLevel.tint(for: group.worstUtilization)
    }

    /// Maps a group's two windows into the provider-agnostic chart input. The
    /// `fetchedAt != epoch` check mirrors how Claude/Codex derive `hasRealData`
    /// (`fetchedAt != .distantPast`): a zero/epoch stamp means "never fetched"
    /// and drives the chart's "Waiting for first fetch…" placeholder.
    static func chartInput(
        for group: AntigravityQuotaSummary.Group, fetchedAt: Date
    ) -> UsageTrendChartInput {
        UsageTrendChartInput(
            fiveHour: group.fiveHour.map { UsageBucket(utilization: $0.utilization, resetsAt: $0.resetTime) },
            sevenDay: group.weekly.map { UsageBucket(utilization: $0.utilization, resetsAt: $0.resetTime) },
            hasRealData: fetchedAt.timeIntervalSince1970 != 0)
    }
}

struct AntigravityUsageDetailView: View {
    let snapshot: AntigravityUsageSnapshot
    let quota: AntigravityQuotaSummary?
    let groupHistory: [String: [UsageHistoryEntry]]

    @AppStorage(AppStorageKeys.displayChartShowAvg)      private var showAvg: Bool = true
    @AppStorage(AppStorageKeys.displayChartShowPaceHint) private var showPaceHint: Bool = true
    // Persisted so the popover reopens on the group the user last viewed instead
    // of snapping back to the default every time the detail view is recreated.
    @AppStorage(AppStorageKeys.antigravityGroupSelection) private var selectedKey: String?
    @AppStorage(AppStorageKeys.displayUsageCompact)      private var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let quota, !quota.groups.isEmpty {
                quotaSection(quota)
            } else {
                unavailableCard
            }
            if Self.shouldShowCreditCard(snapshot: snapshot), let wallet = snapshot.aiCreditsWallet {
                creditsCard(wallet: wallet)
            }
        }
    }

    @ViewBuilder
    private func quotaSection(_ quota: AntigravityQuotaSummary) -> some View {
        let resolved = AntigravityUsageGroupLogic.resolvedKey(selected: selectedKey, quota: quota)
        let group = quota.groups.first { $0.key == resolved } ?? quota.groups[0]

        groupPicker(quota: quota, resolved: resolved)
            .onAppear {
                if selectedKey == nil {
                    selectedKey = AntigravityUsageGroupLogic.defaultSelection(quota: quota)
                }
            }

        let input = AntigravityUsageGroupLogic.chartInput(for: group, fetchedAt: quota.fetchedAt)
        let groupEntries = groupHistory[group.key] ?? []

        if compact {
            // The picker stays: without it, compact would show one arbitrary
            // group's quota with nothing saying which.
            CompactUsageView(input: input, history: groupEntries)
        } else {
            let charts = UsageTrendChart(
                input: input,
                history: groupEntries,
                showAvg: showAvg,
                showPaceHint: showPaceHint)

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Current Session")
                charts.card(for: .session)
            }
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Weekly Limit")
                charts.weeklyCard()
            }
        }
    }

    @ViewBuilder
    private func groupPicker(quota: AntigravityQuotaSummary, resolved: String?) -> some View {
        HStack(spacing: 4) {
            ForEach(quota.groups, id: \.key) { group in
                let isSel = (group.key == resolved)
                Button {
                    selectedKey = group.key
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AntigravityUsageGroupLogic.dotColor(for: group))
                            .frame(width: 7, height: 7)
                        Text(group.displayName ?? group.key)
                            .font(.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSel ? Color.secondary.opacity(0.22) : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSel ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.regularMaterial))
    }

    private var unavailableCard: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle").font(.caption)
            Text("Quota unavailable").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
    }

    // MARK: - Credit card visibility (exposed for tests)

    /// Visible iff wallet has a balance AND the tier exposes an AI Credits
    /// ceiling. Free / Unknown tiers (no ceiling) suppress the card even when
    /// the wallet is present — there's no scale to draw the bar against.
    static func shouldShowCreditCard(snapshot: AntigravityUsageSnapshot) -> Bool {
        snapshot.aiCreditsWallet != nil && snapshot.tier.aiCreditsCeiling != nil
    }

    /// Caption row appears only when we actually read a state.vscdb value.
    /// nil (read failed) suppresses the caption — do not invent an "off".
    static func shouldShowOverageCaption(snapshot: AntigravityUsageSnapshot) -> Bool {
        snapshot.overagesEnabled != nil
    }

    /// Dim the AI Credits bar when overages are explicitly OFF. Read-fail
    /// (nil) keeps the bar lit — there's no signal saying it's inactive.
    static func aiCreditsBarShouldDim(snapshot: AntigravityUsageSnapshot) -> Bool {
        snapshot.overagesEnabled == false
    }

    @ViewBuilder
    private func creditsCard(wallet: Int64) -> some View {
        let ceiling = snapshot.tier.aiCreditsCeiling
        let utilization: Double? = ceiling.flatMap { c -> Double? in
            guard c > 0 else { return nil }
            return max(0, min(100, (1.0 - Double(wallet) / Double(c)) * 100))
        }
        VStack(alignment: .leading, spacing: 4) {
            if Self.shouldShowOverageCaption(snapshot: snapshot) {
                let on = snapshot.overagesEnabled == true
                HStack(spacing: 6) {
                    Text("Enable AI Credit Overages").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Circle().fill(on ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text(on ? "On" : "Off").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Text("AI credits").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let ceiling, ceiling > 0 {
                    Text("\(formatCount(wallet)) / \(formatCount(ceiling))").font(.caption.monospacedDigit())
                } else {
                    Text(formatCount(wallet)).font(.caption.monospacedDigit())
                }
            }
            if let utilization {
                quotaBar(utilization: utilization, forceDim: Self.aiCreditsBarShouldDim(snapshot: snapshot))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
    }

    @ViewBuilder
    private func quotaBar(utilization: Double, forceDim: Bool) -> some View {
        let clamped = max(0, min(100, utilization))
        let remaining = 100 - clamped
        let color: Color = forceDim ? .secondary : UsageLevel.tint(for: clamped)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 4).fill(color.gradient)
                    .frame(width: geo.size.width * CGFloat(remaining / 100))
            }
        }
        .frame(height: 8)
    }

    private func formatCount(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
