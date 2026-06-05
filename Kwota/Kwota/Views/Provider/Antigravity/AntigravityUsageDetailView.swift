//
//  AntigravityUsageDetailView.swift
//  Kwota
//
//  Antigravity Usage tab body.
//
//  Layout: one credit-pool card on top with three rows (AI credits,
//  Prompt credits, Flow credits), then a "Model quota" section below
//  with one row per model. Every bar uses the same shaded `quotaBar`
//  (SwiftUI Charts `BarMark` with `color.gradient`) — same pattern as
//  the Claude and Codex provider views, so the popover feels consistent
//  across providers. Model rows are sorted by family (Gemini Pro →
//  Gemini Flash → Claude → GPT) with variants ordered Low → Medium →
//  High → Thinking within each family.
//

import SwiftUI
import Charts

struct AntigravityUsageDetailView: View {
    let snapshot: AntigravityUsageSnapshot
    let history: [UsageHistoryEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasAnyCreditPool {
                creditsCard
            }

            if let models = snapshot.models, !models.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Model quota")
                    modelsCard(sortedModels(models))
                }
            }
        }
    }

    private var hasAnyCreditPool: Bool {
        Self.shouldShowCreditCard(snapshot: snapshot)
    }

    /// Visible iff wallet has a balance AND the tier exposes an AI Credits
    /// ceiling. Free / Unknown tiers (no ceiling) suppress the card even
    /// when the wallet is present — there's no scale to draw the bar
    /// against. Exposed for tests; do not reach for it elsewhere.
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

    // MARK: - Credit pools (AI + Prompt + Flow, top-down)

    @ViewBuilder
    private var creditsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let wallet = snapshot.aiCreditsWallet {
                aiCreditsPoolRow(available: wallet)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    /// AI credits row. Three sub-rows, top-down:
    ///   1. Caption ("Enable AI Credit Overages  ●  On|Off") — shown only
    ///      when `overagesEnabled != nil`. nil keeps the row absent so a
    ///      flaky SQLite read doesn't invent an off state.
    ///   2. Label + balance ("AI credits  ·  423 / 1,000").
    ///   3. Quota bar — dimmed grey gradient when overages are explicitly
    ///      OFF, normal color otherwise.
    @ViewBuilder
    private func aiCreditsPoolRow(available: Int64) -> some View {
        let ceiling = snapshot.tier.aiCreditsCeiling
        let utilization: Double? = ceiling.flatMap { c -> Double? in
            guard c > 0 else { return nil }
            return max(0, min(100, (1.0 - Double(available) / Double(c)) * 100))
        }
        VStack(alignment: .leading, spacing: 4) {
            if Self.shouldShowOverageCaption(snapshot: snapshot) {
                let on = snapshot.overagesEnabled == true
                HStack(spacing: 6) {
                    Text("Enable AI Credit Overages")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Circle()
                        .fill(on ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(on ? "On" : "Off")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Text("AI credits").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let ceiling, ceiling > 0 {
                    Text("\(formatCount(available)) / \(formatCount(ceiling))")
                        .font(.caption.monospacedDigit())
                } else {
                    Text(formatCount(available)).font(.caption.monospacedDigit())
                }
            }
            if let utilization {
                quotaBar(
                    utilization: utilization,
                    forceDim: Self.aiCreditsBarShouldDim(snapshot: snapshot)
                )
            }
        }
    }

    // MARK: - Models

    @ViewBuilder
    private func modelsCard(_ models: [AntigravityUsageSnapshot.ModelQuota]) -> some View {
        // VStack with zero spacing — each row owns its vertical padding,
        // and a faint Divider after every row except the last produces the
        // hairline separators in the mockup. `Divider().opacity(0.3)`
        // matches the subtle look without overpowering the green bars.
        VStack(spacing: 0) {
            ForEach(Array(models.enumerated()), id: \.offset) { entry in
                modelRow(entry.element)
                    .padding(.vertical, 6)
                if entry.offset < models.count - 1 {
                    Divider().opacity(0.3)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    @ViewBuilder
    private func modelRow(_ model: AntigravityUsageSnapshot.ModelQuota) -> some View {
        // Tighter horizontal layout than before:
        //   - HStack spacing 6 (was 10) — pulls name closer to bar and
        //     bar closer to reset label.
        //   - Name column 150pt (was 180) — releases 30pt to the bar.
        //   - Reset column 50pt (was 60) — releases another 10pt.
        // Net: bar gains ~50pt of horizontal real estate, so the 5 capsule
        // segments fill more of the available row width and stop reading
        // as a clustered group in the middle.
        HStack(spacing: 6) {
            Text(model.label ?? model.modelId ?? "Unknown")
                .font(.caption)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            // remainingFraction is 0.0-1.0 of headroom left. Flip to
            // utilization (% consumed) so the bar fills in the same
            // direction as every other bar in this view and the switcher.
            quotaBar(utilization: model.remainingFraction.map { (1 - $0) * 100 })
                .frame(maxWidth: .infinity)

            Text(resetLabel(for: model.resetTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }

    // MARK: - Bar

    /// Shaded continuous bar used by every row in this view (credit
    /// pools + model rows). Mirrors `PerModelCard.bar` and
    /// `CodexPerCategoryCard.bar`: SwiftUI Charts `BarMark` filled with
    /// `color.gradient`, which gives a subtle top-to-bottom shading
    /// that reads as "3D" against the neutral track.
    ///
    /// `utilization` follows the codebase-wide `UsageBucket.utilization`
    /// convention: 0-100 where higher = more consumed. The bar is rendered
    /// in **battery view**: starts at 100% width when utilization is 0
    /// (full quota), drains toward 0 width as utilization rises (near the
    /// cap). Color is still driven by utilization (`barColor` thresholds
    /// unchanged) so a near-empty bar fires red as expected. `nil`
    /// renders as the empty track only.
    @ViewBuilder
    private func quotaBar(utilization: Double?, forceDim: Bool = false) -> some View {
        let clamped = max(0, min(100, utilization ?? 0))
        let remaining = 100 - clamped
        // forceDim takes precedence over utilization-derived color: the
        // wallet may have headroom but be inactive (overages off), and
        // a green bar in that case would lie about the state.
        let color: Color = forceDim ? .secondary : barColor(utilization: clamped)
        Chart {
            BarMark(
                xStart: .value("Start", 0),
                xEnd:   .value("End", utilization == nil ? 0 : remaining),
                y:      .value("Track", "")
            )
            .foregroundStyle(color.gradient)
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
        .frame(height: 8)
    }

    /// Green below 75% utilization, yellow at 75-90%, red above 90%.
    /// Matches the threshold direction used elsewhere in the popover
    /// (PerModelCard / CodexPerCategoryCard / UsageLevel.tint) — high
    /// utilization = near the cap = red warning.
    private func barColor(utilization: Double) -> Color {
        if utilization > 90 { return .red }
        if utilization > 75 { return .yellow }
        return .green
    }

    // MARK: - Reset label

    /// Formats a reset time as "Nh Mm" / "Md Nh" / "now" / "<1m".
    private func resetLabel(for reset: Date?) -> String {
        guard let reset else { return "—" }
        let delta = reset.timeIntervalSinceNow
        if delta <= 0 { return "now" }
        let seconds = Int(delta)
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if days >= 1 { return "\(days)d \(hours % 24)h" }
        if hours >= 1 { return "\(hours)h \(minutes % 60)m" }
        if minutes >= 1 { return "\(minutes)m" }
        return "<1m"
    }

    // MARK: - Model sort

    /// Stable sort: family bucket ascending (Gemini Pro → Gemini Flash →
    /// Claude → GPT → other) then effort tier ascending (Low → Medium →
    /// High → Thinking → unknown) within each family. Ties fall back to
    /// the original label for a deterministic order.
    fileprivate func sortedModels(
        _ models: [AntigravityUsageSnapshot.ModelQuota]
    ) -> [AntigravityUsageSnapshot.ModelQuota] {
        models.sorted { a, b in
            let ka = AntigravityModelSortKey.from(label: a.label)
            let kb = AntigravityModelSortKey.from(label: b.label)
            if ka.family != kb.family { return ka.family < kb.family }
            if ka.effort != kb.effort { return ka.effort < kb.effort }
            return (a.label ?? "") < (b.label ?? "")
        }
    }

    // MARK: - Formatting

    private func formatCount(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// Sort key used by `AntigravityUsageDetailView.sortedModels`. Exposed at
/// file scope (not nested in the view) so unit tests can pin the comparator
/// behavior without instantiating the SwiftUI view.
struct AntigravityModelSortKey: Equatable {
    /// Family bucket — lower comes first.
    let family: Int
    /// Effort tier within the family — lower comes first.
    let effort: Int

    static func from(label: String?) -> AntigravityModelSortKey {
        let lower = (label ?? "").lowercased()
        let family: Int
        if lower.contains("gemini") {
            family = lower.contains("flash") ? 1 : 0
        } else if lower.contains("claude") {
            family = 2
        } else if lower.contains("gpt") {
            family = 3
        } else {
            family = 99
        }

        let effort: Int
        if lower.contains("(low)")        { effort = 0 }
        else if lower.contains("(medium)") { effort = 1 }
        else if lower.contains("(high)")   { effort = 2 }
        else if lower.contains("(thinking)") { effort = 3 }
        else                                 { effort = 99 }

        return AntigravityModelSortKey(family: family, effort: effort)
    }
}
