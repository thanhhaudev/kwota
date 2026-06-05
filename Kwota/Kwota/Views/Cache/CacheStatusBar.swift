//
//  CacheStatusBar.swift
//  Kwota
//

import Charts
import SwiftUI

/// Header card for the popover Cache tab. Layout:
///   • headline   — big total + "of N cap" suffix, with a filled over-cap pill
///     on the right (only when applicable)
///   • progress   — Swift Charts 3-zone horizontal bar (green in-use, orange
///     overflow, gray headroom). Under cap the domain is the cap, so the green
///     fill is the true `total / cap` fraction; over cap the domain is `total`,
///     so green (to cap) + orange (overflow) fill the bar in proportion
///   • legend     — colored-dot labels for the green/orange zones on the left,
///     cap label on the right; gives the bar a vocabulary so the user doesn't
///     have to infer what each color means
struct CacheStatusBar: View {
    let totalBytes: Int
    let capBytes: Int
    let isAutoCleanEnabled: Bool

    private var isOverCap: Bool { totalBytes > capBytes }
    private var overByBytes: Int { max(0, totalBytes - capBytes) }
    private var inUseBytes: Int { min(totalBytes, capBytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatBytes(totalBytes))
                    .font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(headlineColor)
                Text("of \(formatBytes(capBytes)) cap")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                trailingChip
            }
            .padding(.bottom, 2)
            .accessibilityElement(children: .combine)

            progressChart
            legend
        }
        .kwotaCard()
    }

    /// The over-cap pill is redundant once the legend below the bar shows
    /// `● Over cap X` — we only keep an "Auto-clean off" pill here, which
    /// the legend can't communicate.
    @ViewBuilder
    private var trailingChip: some View {
        if !isAutoCleanEnabled {
            Text("Auto-clean off")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.25)))
                .foregroundStyle(.secondary)
        }
    }

    /// Three-zone bar with a domain that exceeds the cap so a portion of
    /// trailing gray is always visible. The gradient on each segment mirrors
    /// the per-model bars on the Usage tab (`color.gradient`) for visual
    /// continuity between tabs.
    private var progressChart: some View {
        let total = Double(max(1, totalBytes))
        let cap = Double(max(1, capBytes))
        // The bar reflects the true fraction in both states. Under cap the domain
        // is the cap itself, so green fills `total / cap` (e.g. 52.67 of 60 GB
        // reads ~88% full) with gray headroom for the remainder. Once over cap
        // the domain tightens to `total`, filling the bar with green (in use, up
        // to the cap) + orange (overflow) split in proportion to how far over it
        // has spilled.
        let scaleMax = isOverCap ? total : cap

        // Stacked rendering: the longer bar (orange, 0→total) sits underneath
        // and the shorter bar (green, 0→cap) overlays it. The transition at
        // x=cap is a clean handoff from green to orange with no chance of a
        // sub-pixel gap, and the z-order matches the legend semantics
        // (green = in use, orange = over cap).
        return Chart {
            if isOverCap {
                BarMark(
                    xStart: .value("Start", 0.0),
                    xEnd: .value("End", total),
                    y: .value("y", "usage")
                )
                .foregroundStyle(Color.orange.gradient)
            }

            BarMark(
                xStart: .value("Start", 0.0),
                xEnd: .value("End", isOverCap ? cap : total),
                y: .value("y", "usage")
            )
            .foregroundStyle(barUnderGradient)
        }
        .chartXScale(domain: 0...scaleMax)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.background(Color.secondary.opacity(0.18))
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.25), value: totalBytes)
        .animation(.easeInOut(duration: 0.25), value: capBytes)
        .accessibilityElement()
        .accessibilityLabel(chartAccessibilityLabel)
    }

    private var chartAccessibilityLabel: String {
        if isOverCap {
            return "Cache usage \(formatBytes(totalBytes)), \(formatBytes(overByBytes)) over the \(formatBytes(capBytes)) cap"
        }
        return "Cache usage \(formatBytes(totalBytes)) of \(formatBytes(capBytes)) cap"
    }

    /// Always shows the "In use" zone so the user has a colored anchor for
    /// the bar; the "Over cap" item only appears when there's actually a
    /// second zone to label. No right-side cap text — `of N cap` in the
    /// headline already covers that.
    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(color: legendInUseColor, label: "In use \(formatBytes(inUseBytes))")
            if isOverCap {
                legendItem(color: .orange, label: "Over cap \(formatBytes(overByBytes))")
            }
            Spacer(minLength: 0)
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var headlineColor: Color {
        isOverCap ? .orange : .primary
    }

    private var legendInUseColor: Color {
        if !isAutoCleanEnabled { return .secondary }
        return .green
    }

    /// `Color.gradient` auto-generates a subtle top-lighter / bottom-darker
    /// gradient — matches the per-model usage bars on the Usage tab so the
    /// two tabs read as one design language.
    private var barUnderGradient: AnyGradient {
        if !isAutoCleanEnabled { return Color.secondary.opacity(0.55).gradient }
        return Color.green.gradient
    }

    private func formatBytes(_ n: Int) -> String { n.formattedBytes }
}
