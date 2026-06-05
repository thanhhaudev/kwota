//
//  DebugRawJSONLCard.swift
//  Kwota
//

import SwiftUI
import AppKit

struct DebugRawJSONLCard: View {
    let line: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Raw Last JSONL Line")
            cardBody
        }
    }

    @ViewBuilder
    private var cardBody: some View {
        let raw = line ?? ""
        let isEmpty = raw.isEmpty
        ZStack(alignment: .topTrailing) {
            ScrollView {
                Text(isEmpty ? "(empty)" : raw)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(maxHeight: 160)

            if !isEmpty {
                CopyButton(string: raw)
                    .padding(8)
            }
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

struct CopyButton: View {
    let string: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Copy")
    }
}
