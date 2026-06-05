//
//  AboutLinksCard.swift
//  Kwota
//

import SwiftUI
import AppKit

struct AboutLinksCard: View {
    private let githubURL = URL(string: "https://github.com/thanhhaudev/kwota")!

    @State private var hovered = false

    var body: some View {
        Button(action: openGitHub) {
            HStack(spacing: 12) {
                Image("github-mark")
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("github.com/thanhhaudev/kwota")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.06) : Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .settingsCard()
    }

    private func openGitHub() {
        if !NSWorkspace.shared.open(githubURL) {
            AppLog.shared.log("AboutLinksCard: NSWorkspace.open failed for \(githubURL)", level: .warn)
        }
    }
}
