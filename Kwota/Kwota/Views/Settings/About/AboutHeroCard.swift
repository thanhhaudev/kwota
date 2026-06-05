//
//  AboutHeroCard.swift
//  Kwota
//

import SwiftUI
import AppKit

enum AboutVersionString {
    static let dash = "—"

    static func displayLabel(short: String?) -> String {
        "Version \(short ?? dash)"
    }

    static func clipboardText(
        short: String?,
        macOSVersion: String
    ) -> String {
        "Kwota \(short ?? dash) — macOS \(macOSVersion)"
    }
}

struct AboutHeroCard: View {
    let snapshot: SystemSnapshot?

    @State private var didCopy = false

    private var shortVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private var versionLabel: String {
        AboutVersionString.displayLabel(short: shortVersion)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            appIcon
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text("Kwota")
                    .font(.system(size: 28, weight: .semibold))

                Text("Token usage tracker for AI coding assistants")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button(action: copyVersion) {
                    HStack(spacing: 6) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                        Text(didCopy ? "Copied" : versionLabel)
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help("Copy version + system info")
            }

            Spacer(minLength: 0)
        }
        .settingsCard()
    }

    @ViewBuilder
    private var appIcon: some View {
        if let nsImage = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.accentColor.opacity(0.2))
        }
    }

    private func copyVersion() {
        let text = AboutVersionString.clipboardText(
            short: shortVersion,
            macOSVersion: snapshot?.macOSVersion ?? AboutVersionString.dash
        )
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}
