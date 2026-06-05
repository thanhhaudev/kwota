//
//  DebugEventsCard.swift
//  Kwota
//

import SwiftUI

struct DebugEventsCard: View {
    let events: [UsageEvent]

    private let timeWidth: CGFloat = 88
    private let sessionWidth: CGFloat = 116
    private let inputWidth: CGFloat = 72
    private let separatorColor = Color.primary.opacity(0.12)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Recent Events")
            card
        }
    }

    @ViewBuilder
    private var card: some View {
        if events.isEmpty {
            Text("No parsed events yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .cardChrome()
        } else {
            ScrollView {
                table
            }
            .frame(maxHeight: 220)
            .cardChrome()
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.element.uuid) { idx, ev in
                HStack(spacing: 0) {
                    cell(timeText(ev.timestamp), width: timeWidth)
                    vSep
                    cell("s=\(String(ev.sessionId.prefix(8)))", width: sessionWidth)
                    vSep
                    cell("in=\(ev.tokens.input)", width: inputWidth)
                    vSep
                    cell("out=\(ev.tokens.output)", width: nil)
                }
                if idx < events.count - 1 {
                    Rectangle()
                        .fill(separatorColor)
                        .frame(height: 1)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ text: String, width: CGFloat?) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var vSep: some View {
        Rectangle()
            .fill(separatorColor)
            .frame(width: 1)
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

private extension View {
    func cardChrome() -> some View {
        self
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
