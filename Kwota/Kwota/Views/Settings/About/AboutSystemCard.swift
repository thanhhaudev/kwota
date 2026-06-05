//
//  AboutSystemCard.swift
//  Kwota
//

import SwiftUI

struct AboutSystemCard: View {
    let snapshot: SystemSnapshot?

    var body: some View {
        VStack(spacing: 0) {
            row(
                label: "macOS",
                value: snapshot?.macOSVersion
            )

            ForEach(providerRows, id: \.id) { entry in
                Divider()
                row(label: "\(entry.displayName) CLI", value: entry.value, isLoaded: entry.isLoaded)
            }
        }
        .settingsCard()
    }

    private struct ProviderRow {
        let id: String
        let displayName: String
        let value: String?
        let isLoaded: Bool
    }

    private var providerRows: [ProviderRow] {
        guard let snapshot else { return [] }
        return snapshot.providerCLIs.map {
            ProviderRow(
                id: $0.providerIDRaw,
                displayName: $0.displayName,
                value: $0.version ?? "Not installed",
                isLoaded: true
            )
        }
    }

    @ViewBuilder
    private func row(label: String, value: String?, isLoaded: Bool = true) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if isLoaded, let value {
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(value == "Not installed" ? .secondary : .primary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 28)
    }
}
