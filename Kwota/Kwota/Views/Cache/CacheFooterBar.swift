//
//  CacheFooterBar.swift
//  Kwota
//

import SwiftUI

/// Footer for the popover Cache tab. Single-row layout: rescan control on
/// the left, Clean-now button on the right with a small AI sparkles button
/// for evaluation. Ambient info (next scan, last clean) lives in the header
/// card or shows as transient state in the rows themselves — the footer is
/// strictly actions.
struct CacheFooterBar: View {
    /// Total bytes the Clean-now button would free if pressed. Sum of
    /// auto-on rows, regardless of cap. Drives both label and enabled state.
    let cleanableBytes: Int
    let isRescanning: Bool
    /// True while a bulk AI evaluation is in flight. Swaps the sparkles icon
    /// for a spinner so the user gets feedback even if the popover is the
    /// only surface they're watching.
    let isEvaluatingAI: Bool
    /// Number of rows that currently lack an evaluation. Drives the AI
    /// button's tint (accent when there's work to do, secondary otherwise)
    /// and the helper tooltip.
    let unevaluatedCount: Int
    let onCleanNow: () -> Void
    let onRescan: () -> Void
    let onEvaluateAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            rescanControl
            Spacer()
            Button(
                cleanableBytes > 0 ? "Clean now · \(formatBytes(cleanableBytes))" : "Clean now",
                systemImage: "eraser.fill",
                action: onCleanNow
            )
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(cleanableBytes == 0 || isRescanning)
            aiButton
        }
    }

    /// Square (slightly rounded) AI button — matches the rounded-rect feel
    /// of `.borderedProminent` `.controlSize(.small)` next to it, so the two
    /// controls share the same silhouette family.
    @ViewBuilder
    private var aiButton: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Button(action: onEvaluateAll) {
            Group {
                if isEvaluatingAI {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(aiButtonForeground)
                }
            }
            .frame(width: 22, height: 22)
            .background(shape.fill(aiButtonBackground))
            .overlay(shape.stroke(aiButtonStroke, lineWidth: 0.5))
            .contentShape(shape)
            // `.help()` here (inside the Button label) fires on hover even
            // when the Button is `.disabled` — disabled buttons swallow
            // tooltips applied at the Button level on older macOS.
            .help(aiButtonTooltip)
        }
        .buttonStyle(.plain)
        .disabled(isEvaluatingAI || unevaluatedCount == 0)
        .accessibilityLabel(Text(aiButtonTooltip))
    }

    /// Active tint follows the system accent (matches tab selection + other
    /// tinted controls in the popover) instead of a hard-coded green, so the
    /// button reads as a system control rather than a status indicator.
    private var aiButtonForeground: Color {
        unevaluatedCount > 0 ? .accentColor : .secondary
    }

    private var aiButtonBackground: Color {
        Color.secondary.opacity(0.12)
    }

    private var aiButtonStroke: Color {
        Color.secondary.opacity(0.20)
    }

    private var aiButtonTooltip: String {
        if isEvaluatingAI { return "Evaluating with AI…" }
        if unevaluatedCount == 0 { return "All folders evaluated" }
        return "Evaluate \(unevaluatedCount) folder\(unevaluatedCount == 1 ? "" : "s") with AI"
    }

    @ViewBuilder
    private var rescanControl: some View {
        if isRescanning {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button(action: onRescan) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("Rescan")
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func formatBytes(_ n: Int) -> String { n.formattedBytes }
}
