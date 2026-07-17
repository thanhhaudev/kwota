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

    private let opusColor: Color = .blue
    private let sonnetColor: Color = .orange
    private let omeletteColor: Color = .purple
    private let fableColor: Color = .pink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let opus {
                UsageBatteryRow(label: "Opus", utilization: opus.utilization, color: opusColor)
            }
            if let sonnet {
                UsageBatteryRow(label: "Sonnet only", utilization: sonnet.utilization, color: sonnetColor)
            }
            if let fable {
                UsageBatteryRow(label: "Fable only", utilization: fable.utilization, color: fableColor)
            }
            if let omelette {
                UsageBatteryRow(label: "Claude Design", utilization: omelette.utilization, color: omeletteColor)
            }
        }
    }
}
