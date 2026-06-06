//
//  AboutSystemCard.swift
//  Kwota
//

import SwiftUI

struct AboutSystemCard: View {
    let snapshot: SystemSnapshot?

    var body: some View {
        VStack(spacing: 0) {
            row(label: "macOS", value: snapshot?.macOSVersion)

            ForEach(snapshot?.installedComponents ?? []) { component in
                Divider()
                row(label: component.label, value: component.version)
            }
        }
        .settingsCard()
    }

    @ViewBuilder
    private func row(label: String, value: String?) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if let value {
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 28)
    }
}
