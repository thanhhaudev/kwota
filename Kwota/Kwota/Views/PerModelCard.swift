//
//  PerModelCard.swift
//  Kwota
//
//  Stacked per-model utilization rows. Each row is rendered only when the
//  corresponding bucket is non-nil — matches Anthropic's claude.ai settings
//  page, which omits buckets the account doesn't have rather than rendering
//  empty placeholders. CLI-auth Messages API typically yields all-nil here,
//  so the caller gates the section on `hasPerModelData` to hide the whole
//  card in that case.
//
//  Row rendering lives in the shared `UsageBatteryRow`.
//

import SwiftUI

struct PerModelCard: View {
    let opus: UsageBucket?
    let sonnet: UsageBucket?
    /// "Claude Design" — Anthropic's internal codename is `omelette`. Surface
    /// label diverges from field name on purpose; if the codename rotates, the
    /// decoder yields nil and the row vanishes. See `UsageSnapshot.sevenDayOmelette`.
    let omelette: UsageBucket?
    /// "Fable only" — sourced from the API's `limits[]` weekly_scoped entry
    /// (see `UsageSnapshot.sevenDayFable`). Pink matches the pinned family
    /// color in `StatsModelPalette` so the model reads consistently across
    /// the Usage and Stats tabs.
    let fable: UsageBucket?
    var labelWidth: CGFloat = 90
    var isCompact: Bool = false

    private let opusColor: Color = .blue
    private let sonnetColor: Color = .orange
    private let omeletteColor: Color = .purple
    private let fableColor: Color = .pink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isCompact { Divider() }
            if let opus { row(label: "Opus", bucket: opus, color: opusColor) }
            if let sonnet { row(label: "Sonnet only", bucket: sonnet, color: sonnetColor) }
            if let fable { row(label: "Fable only", bucket: fable, color: fableColor) }
            if let omelette { row(label: "Claude Design", bucket: omelette, color: omeletteColor) }
        }
    }

    /// Compact mode paints the meter by urgency (CompactStatusRow); full view
    /// keeps the category-colored UsageBatteryRow.
    @ViewBuilder
    private func row(label: String, bucket: UsageBucket, color: Color) -> some View {
        if isCompact {
            CompactStatusRow(
                label: label,
                utilization: bucket.utilization,
                tag: CompactUsageStatus.levelTag(utilization: bucket.utilization)
            )
        } else {
            UsageBatteryRow(
                label: label,
                utilization: bucket.utilization,
                color: color,
                labelWidth: labelWidth
            )
        }
    }
}
