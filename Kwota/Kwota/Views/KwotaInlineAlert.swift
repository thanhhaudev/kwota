//
//  KwotaInlineAlert.swift
//  Kwota
//
//  Shared chrome for inline status banners (session expiry, stale data).
//  Matches the kwotaCard() visual system: regularMaterial + continuous
//  cornerRadius 10 + soft stroke + soft shadow. Severity is signalled by a
//  tinted icon pill at the leading edge, not by a saturated background fill.
//
//  Generic over `Detail` so callers can pass a plain `String` (the common
//  case) or any `View` — e.g. a `TimelineView` for a live countdown. Keeping
//  the dynamic content scoped to `detail` avoids re-evaluating the material,
//  stroke, and shadow on every tick.
//

import SwiftUI

struct KwotaInlineAlert<Detail: View>: View {
    let tint: Color
    let icon: String
    let title: String
    let detail: Detail
    let actionTitle: String?
    let onAction: (() -> Void)?
    /// When true the action slot renders a small spinner instead of the
    /// button — the action is in flight and a second click would be
    /// meaningless. Keeps the banner's height stable while it works.
    let isActionBusy: Bool

    init(
        tint: Color,
        icon: String,
        title: String,
        @ViewBuilder detail: () -> Detail,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil,
        isActionBusy: Bool = false
    ) {
        self.tint = tint
        self.icon = icon
        self.title = title
        self.detail = detail()
        self.actionTitle = actionTitle
        self.onAction = onAction
        self.isActionBusy = isActionBusy
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            iconPill
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.callout)
                        .fontWeight(.medium)
                    if isActionBusy {
                        Spacer(minLength: 8)
                        ProgressView()
                            .controlSize(.small)
                            // VoiceOver: the action button this spinner
                            // replaces was focusable; without a label the
                            // slot turns into an anonymous element.
                            .accessibilityLabel("In progress")
                    } else if let actionTitle, let onAction {
                        Spacer(minLength: 8)
                        Button(actionTitle, action: onAction)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                detail
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
    }

    private var iconPill: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.opacity(0.18))
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint.opacity(0.95))
                    .accessibilityHidden(true)
            )
    }
}

extension KwotaInlineAlert where Detail == Text {
    init(
        tint: Color,
        icon: String,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil,
        isActionBusy: Bool = false
    ) {
        self.init(
            tint: tint,
            icon: icon,
            title: title,
            detail: { Text(detail) },
            actionTitle: actionTitle,
            onAction: onAction,
            isActionBusy: isActionBusy
        )
    }
}
