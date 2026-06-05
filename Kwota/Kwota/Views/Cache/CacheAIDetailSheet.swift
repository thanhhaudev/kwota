//
//  CacheAIDetailSheet.swift
//  Kwota
//

import SwiftUI

/// Modal detail for one row's AI evaluation. Shows safety verdict, the
/// short inline warning, the full "purpose" copy, and optional detail
/// paragraph plus provenance (model + evaluated-at). Re-evaluate triggers
/// the same stub action the row menu does, scoped to the row that opened
/// the sheet.
struct CacheAIDetailSheet: View {
    let row: CachePathRow
    let isReEvaluating: Bool
    let onReEvaluate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 380)
        // No height constraints — popover sizes to its content. Short
        // evaluations (no detail block) collapse cleanly; long ones grow
        // up to whatever the screen affords. ScrollView was removed because
        // single-row AI evaluations don't need scrolling at realistic copy
        // lengths, and the empty trailing space when content was short was
        // worse than the rare overflow case.
        //
        // Esc routes through `.onExitCommand` because stacking two
        // `.keyboardShortcut` modifiers on the Done button only registers
        // the last one (SwiftUI preference-key semantics), so Enter
        // wouldn't dismiss when Esc was also bound.
        .onExitCommand { onDismiss() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let eval = row.aiEvaluation {
                verdictBlock(eval)
                if let warning = eval.warning, !warning.isEmpty {
                    warningBlock(warning)
                }
                purposeBlock(eval)
                if let detail = eval.detail, !detail.isEmpty {
                    detailBlock(detail)
                }
                provenanceBlock(eval)
            } else {
                Text("No evaluation yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(row.path.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Blocks

    private func verdictBlock(_ eval: CacheAIEvaluation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: verdictIcon(eval.safety))
                .font(.system(size: 22))
                .foregroundStyle(verdictColor(eval.safety))
            VStack(alignment: .leading, spacing: 2) {
                Text(verdictTitle(eval.safety))
                    .font(.system(size: 14, weight: .semibold))
                Text(verdictSubtitle(eval.safety))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(verdictColor(eval.safety).opacity(0.08))
                .stroke(verdictColor(eval.safety).opacity(0.20), lineWidth: 0.5)
        )
    }

    private func warningBlock(_ text: String) -> some View {
        sectionBlock(title: "Warning") {
            Text(text)
        }
    }

    private func purposeBlock(_ eval: CacheAIEvaluation) -> some View {
        sectionBlock(title: "Purpose") {
            Text(eval.purpose)
        }
    }

    private func detailBlock(_ text: String) -> some View {
        sectionBlock(title: "Detail") {
            Text(text)
        }
    }

    private func sectionBlock<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title)
            content()
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                // Match SectionHeader's `.padding(.leading, 4)` so the body
                // sits flush under the title instead of hanging 4pt to the
                // left of it.
                .padding(.leading, 4)
        }
    }

    private func provenanceBlock(_ eval: CacheAIEvaluation) -> some View {
        HStack(spacing: 4) {
            Text(eval.modelUsed)
            Text("·")
            Text("evaluated \(RelativeFormatters.full.localizedString(for: eval.evaluatedAt, relativeTo: Date()))")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        // Align with the section body text above (which is also offset by 4pt
        // to match SectionHeader's leading padding).
        .padding(.leading, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if isReEvaluating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Re-evaluating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Re-evaluate", systemImage: "sparkles", action: onReEvaluate)
                .disabled(isReEvaluating)
            Button("Done", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Verdict copy/icons/colors

    private func verdictIcon(_ s: CacheAIEvaluation.Safety) -> String {
        switch s {
        case .safe:    return "checkmark.seal.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .risky:   return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private func verdictColor(_ s: CacheAIEvaluation.Safety) -> Color {
        switch s {
        case .safe:    return .green
        case .caution: return .orange
        case .risky:   return .red
        case .unknown: return .secondary
        }
    }

    private func verdictTitle(_ s: CacheAIEvaluation.Safety) -> String {
        switch s {
        case .safe:    return "Safe to clean"
        case .caution: return "Clean with caution"
        case .risky:   return "Avoid auto-clean"
        case .unknown: return "Verdict unavailable"
        }
    }

    private func verdictSubtitle(_ s: CacheAIEvaluation.Safety) -> String {
        switch s {
        case .safe:    return "Tool will rebuild content on next use."
        case .caution: return "Deletion has side effects worth knowing."
        case .risky:   return "Contains state or data the user owns."
        case .unknown: return "Re-evaluate or inspect manually."
        }
    }
}
