//
//  DebugLogCard.swift
//  Kwota
//

import SwiftUI

struct DebugLogCard: View {
    let refreshNonce: Int

    @State private var logSnapshot: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Log")
            cardBody
        }
        .onAppear { reload() }
        .onChange(of: refreshNonce) { _, _ in reload() }
    }

    @ViewBuilder
    private var cardBody: some View {
        if logSnapshot.isEmpty {
            Text("No log entries yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    Color(.controlBackgroundColor).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        } else {
            let joined = logSnapshot.suffix(200).joined(separator: "\n")
            ZStack(alignment: .topTrailing) {
                ScrollView {
                    Text(joined)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 280)

                CopyButton(string: joined)
                    .padding(8)
            }
            .background(
                Color(.controlBackgroundColor).opacity(0.6),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func reload() {
        logSnapshot = AppLog.shared.snapshot()
    }
}
