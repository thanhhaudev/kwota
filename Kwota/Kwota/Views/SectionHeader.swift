//
//  SectionHeader.swift
//  Kwota
//
//  Lightweight uppercase label sitting above a card — macOS System Settings convention.
//

import SwiftUI

struct SectionHeader<Trailing: View>: View {
    let title: String
    var info: [String]? = nil
    /// Optional control rendered flush-right on the header row (e.g. a range
    /// picker). Defaults to `EmptyView` via the convenience init below, so
    /// existing `SectionHeader(title:)` call sites are unchanged.
    @ViewBuilder var trailing: () -> Trailing

    @State private var showingInfo = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(1.5)
                .textCase(.uppercase)

            if let info, !info.isEmpty {
                Button {
                    showingInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More information about \(title)")
                .popover(isPresented: $showingInfo) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(info, id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 280, alignment: .leading)
                }
            }

            Spacer(minLength: 0)

            trailing()
        }
        .padding(.leading, 4)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, info: [String]? = nil) {
        self.init(title: title, info: info, trailing: { EmptyView() })
    }
}
