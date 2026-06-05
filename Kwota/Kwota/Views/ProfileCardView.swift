//
//  ProfileCardView.swift
//  Kwota
//

import SwiftUI
import AppKit

struct ProfileCardView: View {
    let plan: String?
    let renewalText: String?
    /// Help-text body shown when the info icon is tapped next to
    /// renewalText. Empty string suppresses the icon; nil falls back to
    /// a generic estimate caveat. Caller (MenuBarViewModel) provides the
    /// centralized wording so the view stays presentation-only.
    let renewalTooltip: String?
    let activeProfileName: String
    /// Asset catalog name (e.g. "Mascot", "CodexLogo") or SF Symbol the
    /// card renders in the trailing 32pt slot. Defaults to "Mascot" so
    /// existing call sites keep their Claude-branded artwork.
    let iconAssetName: String
    /// When non-nil, renders a small filled circle at the bottom-trailing
    /// corner of the avatar. Color comes from
    /// `ProfileSwitcherCard.quotaDotColor(for:)`. Callers pass nil while
    /// loading or when no summary is available — no dot is preferable
    /// to a misleading green.
    let quotaDotColor: Color?
    /// SF Symbol name rendered in the trailing slot of the card
    /// (right edge, after the populatedState VStack). Used by the
    /// switcher card to host the expand/collapse chevron inside the
    /// card chrome instead of dangling it outside. nil suppresses the
    /// trailing slot entirely so non-switcher callers stay unchanged.
    let trailingSymbolName: String?

    /// Click-to-disclose state for the renewal-estimate help bubble.
    /// Rendered via `.popover` (same as SectionHeader) — popover content
    /// lives in its own NSWindow, so it cannot be clipped by sibling cards
    /// or covered when ProfileCardView is the topmost card in the
    /// ScrollView (no rate-limit banner above to push it down). The
    /// previous overlay+offset approach left the bubble inside the
    /// ScrollView's clip and inside ProfileCardView's source-order slot,
    /// which let later siblings paint over its drawn pixels. `.help()`
    /// is not an option — it does not fire inside MenuBarExtra panels.
    @State private var showRenewalHelp: Bool = false

    init(
        plan: String?,
        renewalText: String?,
        renewalTooltip: String? = nil,
        activeProfileName: String,
        iconAssetName: String = "Mascot",
        quotaDotColor: Color? = nil,
        trailingSymbolName: String? = nil
    ) {
        self.plan = plan
        self.renewalText = renewalText
        self.renewalTooltip = renewalTooltip
        self.activeProfileName = activeProfileName
        self.iconAssetName = iconAssetName
        self.quotaDotColor = quotaDotColor
        self.trailingSymbolName = trailingSymbolName
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                ProviderIconView(assetName: iconAssetName, size: 24)
            }
            .frame(width: 40, height: 40)
            .overlay(alignment: .bottomTrailing) {
                if let quotaDotColor {
                    Circle()
                        .fill(quotaDotColor)
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle()
                                .stroke(.background, lineWidth: 1.5)
                        )
                        .offset(x: -1, y: -1)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                populatedState
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let trailingSymbolName {
                Image(systemName: trailingSymbolName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .kwotaCard()
    }

    private var populatedState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(activeProfileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)

            Text("Plan: \(plan ?? "Free")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let renewalText {
                HStack(spacing: 3) {
                    Text(renewalText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let tip = renewalTooltip, !tip.isEmpty {
                        Button {
                            showRenewalHelp.toggle()
                        } label: {
                            Image(systemName: showRenewalHelp ? "info.circle.fill" : "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tip)
                        .popover(isPresented: $showRenewalHelp, arrowEdge: .top) {
                            Text(tip)
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 220, alignment: .leading)
                                .padding(12)
                        }
                    }
                }
            }
        }
    }

}
