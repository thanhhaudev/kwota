//
//  SettingsGroupedSection.swift
//  Kwota
//

import SwiftUI

/// Mockup grammar: sentence-case 13pt semibold caption + rounded container
/// holding rows separated by inset dividers + optional secondary-color footer hint.
struct SettingsGroupedSection<Content: View>: View {
    let caption: String
    let footer: String?
    @ViewBuilder var content: () -> Content

    init(caption: String,
         footer: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.caption = caption
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content()
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Pill rendered inside `SettingsRow.leadingBadges`. Caller supplies both
/// fill and text color so the row component stays palette-agnostic.
/// Convention: `background = foreground.opacity(0.18)` for accent badges,
/// `0.15` for `.secondary`-styled neutral badges (matches the previous
/// hand-built tracked-folder badges).
struct SettingsRowBadge: Identifiable {
    let id = UUID()
    let text: String
    let foreground: Color
    let background: Color
}

/// Renders a single `SettingsRowBadge` with the exact dimensions the
/// tracked-folder row used before this refactor (10pt medium text,
/// 5×1pt inset, capsule fill).
private struct SettingsRowBadgeView: View {
    let badge: SettingsRowBadge
    var body: some View {
        Text(badge.text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(badge.background))
            .foregroundStyle(badge.foreground)
    }
}

/// Standard row inside a grouped section: leading title/subtitle, trailing
/// control. Pass `leadingBadges` to append pill badges to the right of the
/// title (used by tracked-folder rows for caution/risky/custom markers).
struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let leadingBadges: [SettingsRowBadge]
    @ViewBuilder var trailing: () -> Trailing

    init(title: String,
         subtitle: String? = nil,
         leadingBadges: [SettingsRowBadge] = [],
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.leadingBadges = leadingBadges
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if leadingBadges.isEmpty {
                    Text(title).font(.system(size: 13))
                } else {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13))
                        ForEach(leadingBadges) { badge in
                            SettingsRowBadgeView(badge: badge)
                        }
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// Hairline divider for in-card row separators. 0.5pt line in
/// `separatorColor`, symmetrically inset 14pt on both edges to mirror the
/// row content's horizontal padding so the line reads as a clean break
/// between rows rather than running into the card's rounded corners.
struct SettingsSectionDivider: View {
    var leadingInset: CGFloat = 14
    var trailingInset: CGFloat = 14

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 0.5)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
    }
}
