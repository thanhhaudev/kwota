//
//  CacheRowView.swift
//  Kwota
//

import SwiftUI

/// Path display for cache rows: a row inside the user's home directory
/// drops the "/Users/<name>" prefix — ~40% of the line that carries no
/// information, every user row shares it — and signals the scope with a
/// person glyph instead. The display keeps its leading slash so the glyph
/// reads as a path segment ("👤/Library/Caches/…"). Paths outside home
/// pass through unchanged.
enum CachePathDisplay {
    static func abbreviate(_ path: String, home: String) -> (inHome: Bool, display: String) {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, path.hasPrefix(home + "/") else {
            return (false, path)
        }
        let remainder = String(path.dropFirst(home.count))
        guard remainder.count > 1 else { return (false, path) }
        return (true, remainder)
    }
}

/// Single row in the popover Cache list. Three-line layout (AI annotation
/// is conditional): name + chips on top, size + path in the middle,
/// optional AI summary on the bottom. Trailing ⋯ menu houses per-row
/// actions.
struct CacheRowView: View {
    let row: CachePathRow
    /// True when this (non-system) row shares its name with a system row, so
    /// a `user` pill is shown to disambiguate the scope. Computed by the
    /// parent from the full row list — see `CachePathRow.scopeCollisionNames`.
    let showsUserScopePill: Bool
    let isReEvaluating: Bool
    /// True while THIS row's per-row Clean is in flight (trash-move plus
    /// the forced rescan). Dims the row, floats a "Removing…" overlay,
    /// blocks interaction, and disables the ⋯ menu's "Clean now".
    let isCleaning: Bool
    let onCleanNow: () -> Void
    let onReEvaluate: () -> Void
    let onToggleAuto: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onRemove: () -> Void
    let onShowAIDetail: () -> Void

    var body: some View {
        rowContent
            // While the row's clean is in flight: dim it and block
            // interaction so a half-deleted row can't be re-triggered or
            // have its toggles flipped. The in-progress status itself is
            // inline (the size badge swaps to a spinner + "Removing…") —
            // no full-row overlay, so the path/info stays readable.
            .opacity(isCleaning ? 0.55 : 1)
            .allowsHitTesting(!isCleaning)
            .animation(.easeInOut(duration: 0.2), value: isCleaning)
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(row.exists ? .primary : .secondary)
                    chips
                    Spacer(minLength: 8)
                    CacheRowMenu(
                        row: row,
                        isReEvaluating: isReEvaluating,
                        isCleaning: isCleaning,
                        onCleanNow: onCleanNow,
                        onReEvaluate: onReEvaluate,
                        onToggleAuto: onToggleAuto,
                        onReveal: onReveal,
                        onCopyPath: onCopyPath,
                        onRemove: onRemove,
                        onShowDetail: onShowAIDetail
                    )
                }

                infoLine

                aiAnnotation
            }
        }
        .padding(.vertical, 6)
        // `.contain` (not `.combine`) so the ⋯ menu and AI annotation button
        // stay individually navigable to VoiceOver. `.combine` flattens
        // descendants into a single element and swallows their actions.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityDescription))
    }

    /// Middle info line: "💾 1.2 GB · 👤/Library/Caches/Claude". Size leads
    /// the line (left-anchored, monospaced) so sizes still scan vertically
    /// across rows after moving off the top line; the path truncates in the
    /// middle independently so the size never gets cut. While the row's
    /// clean is in flight the size segment swaps in place to a mini spinner
    /// + "Removing…" — same inline feedback as the old trailing capsule.
    @ViewBuilder
    private var infoLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if isCleaning {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Removing…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text("Removing \(row.displayName)"))
            } else {
                (inlineIcon("internaldrive")
                    + Text(row.exists ? formatBytes(row.sizeBytes) : "—"))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(row.exists ? .primary : .secondary)
            }
            pathText
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                // The home prefix is hidden in the display string — keep
                // the full literal path one hover away.
                .help(row.path.path)
        }
    }

    /// "· 👤/Library/Caches/Claude" for home-relative paths, the raw path
    /// for everything else (e.g. /Library/Caches system rows). The person
    /// glyph sits flush against the slash — no trailing space — so it
    /// reads as the path's first segment.
    private var pathText: Text {
        let abbrev = CachePathDisplay.abbreviate(row.path.path, home: NSHomeDirectory())
        if abbrev.inHome {
            return Text("· ")
                + Text(Image(systemName: "person.fill"))
                    .font(.system(size: 8.5))
                    .baselineOffset(0.5)
                + Text(abbrev.display)
        }
        return Text("· \(abbrev.display)")
    }

    /// Field glyph inside the info line — same sizing trick as the Awake
    /// tab's agent-process subtitle: slightly under the text size and
    /// nudged up half a point so it reads as a label, not a character.
    private func inlineIcon(_ systemName: String) -> Text {
        Text(Image(systemName: systemName))
            .font(.system(size: 8.5))
            .baselineOffset(0.5)
            + Text(" ")
    }

    @ViewBuilder
    private var chips: some View {
        // Chip reads `effectiveRisk` (AI override > hand-curated) so the
        // sparkles annotation and the chip can't disagree — was a common
        // source of confusion in Phase 1.
        if row.effectiveRisk == .caution {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange.opacity(0.85))
                .help("Shared store — clearing may force re-downloads across projects.")
        } else if row.effectiveRisk == .risky {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red.opacity(0.85))
                .help("Risky — folder may contain state or data the user owns.")
        }
        if row.isCustom && !row.isSystem {
            Text("custom")
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .foregroundStyle(.secondary)
        }
        if showsUserScopePill {
            Text("user")
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .foregroundStyle(.secondary)
        }
        if row.isSystem {
            Text("system")
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.blue.opacity(0.15)))
                .foregroundStyle(.blue)
        }
    }

    @ViewBuilder
    private var aiAnnotation: some View {
        if isReEvaluating {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Re-evaluating…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } else if let eval = row.aiEvaluation {
            Button(action: onShowAIDetail) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(aiTint(eval.safety))
                    Text(annotationText(eval))
                        .font(.system(size: 11))
                        .foregroundStyle(aiTint(eval.safety).opacity(0.95))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private func annotationText(_ eval: CacheAIEvaluation) -> String {
        switch eval.safety {
        case .safe:    return eval.warning ?? "Safe to clean"
        case .caution: return eval.warning ?? "Clean with caution"
        case .risky:   return eval.warning ?? "Avoid auto-clean"
        case .unknown: return "Verdict unavailable"
        }
    }

    private func aiTint(_ s: CacheAIEvaluation.Safety) -> Color {
        switch s {
        case .safe:    return .green
        case .caution: return .orange
        case .risky:   return .red
        case .unknown: return .secondary
        }
    }

    private var accessibilityDescription: String {
        var parts: [String] = [row.displayName, formatBytes(row.sizeBytes)]
        // Use `effectiveRisk` so VoiceOver matches the visible chip — the
        // chip reads the AI override when one exists, this previously
        // read the hand-curated value and could disagree.
        switch row.effectiveRisk {
        case .risky:   parts.append("risky")
        case .caution: parts.append("shared store")
        case .safe:    break
        }
        if row.isCustom { parts.append("custom path") }
        if showsUserScopePill { parts.append("user copy") }
        if row.isSystem { parts.append("system cache") }
        parts.append(row.autoCleanEnabled ? "auto-clean on" : "auto-clean off")
        if let eval = row.aiEvaluation {
            parts.append(annotationText(eval))
        }
        return parts.joined(separator: ", ")
    }

    private var dotColor: Color {
        guard row.exists else { return .secondary.opacity(0.4) }
        return row.autoCleanEnabled ? .green : .secondary.opacity(0.45)
    }

    private func formatBytes(_ n: Int) -> String { n.formattedBytes }
}
