//
//  AgentProcessesCard.swift
//  Kwota
//
//  "Agent Processes" section body for the Awake tab. Lists agent-related
//  processes from the VM's poll snapshot; orphan rows (ppid == 1) carry an
//  orange badge and the only Kill affordance. Live rows are informational.
//

import SwiftUI

/// Row-visibility policy for the Agent Processes card. The popover sizes
/// itself to content (`fixedSize` in KeepAwakeTabView), so an unbounded list
/// — 14 live claude sessions is a real-world snapshot — crops the whole
/// window. Orphans are the actionable rows and are never hidden; live rows
/// are capped behind a Show-all toggle, mirroring CacheTabView's tail toggle.
enum AgentProcessListModel {
    static let liveCap = 5

    /// Input is the VM's orphans-first sorted snapshot; the cap therefore
    /// only ever trims the live tail.
    static func visible(_ all: [AgentProcessInfo], showAll: Bool) -> [AgentProcessInfo] {
        if showAll { return all }
        let orphans = all.filter(\.isOrphan)
        let live = all.filter { !$0.isOrphan }
        return orphans + live.prefix(liveCap)
    }

    static func hiddenCount(_ all: [AgentProcessInfo], showAll: Bool) -> Int {
        showAll ? 0 : max(0, all.filter { !$0.isOrphan }.count - liveCap)
    }
}

struct AgentProcessesCard: View {
    let vm: MenuBarViewModel

    @State private var killTarget: AgentProcessInfo?
    @State private var showKillAlert = false
    @State private var showAllProcesses = false

    /// Expanded-list bound: keeps the popover under screen height even with
    /// dozens of rows; the list scrolls internally past this.
    private let expandedMaxHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                if vm.agentProcesses.isEmpty {
                    Text("No agent processes running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    rowList
                    if AgentProcessListModel.hiddenCount(vm.agentProcesses, showAll: false) > 0 {
                        tailToggle
                    }
                }
            }
            .kwotaCard()

            if let notice = vm.agentProcessKillNotice {
                KwotaInlineAlert(
                    tint: .orange,
                    icon: "exclamationmark.triangle.fill",
                    title: "Kill failed",
                    detail: notice
                )
            }
        }
        .alert("Kill orphan process?", isPresented: $showKillAlert, presenting: killTarget) { proc in
            Button("Kill", role: .destructive) {
                Task { await vm.killOrphanAgentProcess(pid: proc.pid) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { proc in
            Text("\(proc.commandDisplay) (PID \(String(proc.pid))) lost its parent and was re-parented to launchd. SIGTERM will be sent.")
        }
    }

    /// Collapsed: plain stack (orphans + first capped live rows — short).
    /// Expanded: bounded internal scroll so the popover never outgrows the
    /// screen no matter how many sessions are alive.
    @ViewBuilder
    private var rowList: some View {
        let visible = AgentProcessListModel.visible(vm.agentProcesses, showAll: showAllProcesses)
        if showAllProcesses {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visible) { proc in
                        row(proc)
                    }
                }
            }
            .frame(maxHeight: expandedMaxHeight)
        } else {
            ForEach(visible) { proc in
                row(proc)
            }
        }
    }

    /// Link-style footer toggle — same native "Show All" pattern as
    /// CacheTabView's tail toggle.
    private var tailToggle: some View {
        let hidden = AgentProcessListModel.hiddenCount(vm.agentProcesses, showAll: false)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                showAllProcesses.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: showAllProcesses ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(showAllProcesses ? "Show fewer" : "Show all (\(vm.agentProcesses.count))")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showAllProcesses
            ? "Show fewer agent processes"
            : "Show all agent processes, \(hidden) hidden")
    }

    private func row(_ proc: AgentProcessInfo) -> some View {
        HStack(spacing: 8) {
            ProviderIconView(assetName: iconAsset(for: proc.provider), size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(proc.commandDisplay)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("PID \(String(proc.pid)) · \(String(format: "%.1f", proc.cpuPercent))% · \(proc.elapsed)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if proc.isOrphan {
                Text("Orphan")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
                    .foregroundStyle(.orange)
                Button("Kill") {
                    killTarget = proc
                    showKillAlert = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
    }

    private func iconAsset(for provider: ProviderID) -> String {
        vm.registry.provider(for: provider)?.iconAssetName ?? "Mascot"
    }
}
