//
//  DebugPanelView.swift
//  Kwota
//

import SwiftUI

struct DebugPanelView: View {
    let vm: MenuBarViewModel

    @State private var refreshNonce: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader
                DebugEventsCard(events: vm.recentEvents)
                DebugRawJSONLCard(line: vm.usage.reader.lastSeenLine())
                DebugLogCard(refreshNonce: refreshNonce)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center) {
            Text("Inspect parsed events, raw input, and runtime logs.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 8) {
                Button {
                    refreshNonce &+= 1
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    Task { await DebugReportExporter.shared.present(vm: vm) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }
}
