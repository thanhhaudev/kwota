//
//  AgentProcessesCard.swift
//  Kwota
//
//  "Agent Processes" section body for the Awake tab. Lists agent-related
//  processes from the VM's poll snapshot; orphan rows (ppid == 1) carry an
//  orange badge and the only Kill affordance. Live rows are informational.
//

import SwiftUI

struct AgentProcessesCard: View {
    let vm: MenuBarViewModel

    @State private var killTarget: AgentProcessInfo?
    @State private var showKillAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                if vm.agentProcesses.isEmpty {
                    Text("No agent processes running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.agentProcesses) { proc in
                        row(proc)
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
