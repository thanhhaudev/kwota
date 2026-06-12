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
    @State private var hoveredKillPID: Int32?

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
        .alert("Kill \(killTarget?.commandDisplay ?? "process")?", isPresented: $showKillAlert, presenting: killTarget) { proc in
            Button("Kill", role: .destructive) {
                Task { await vm.killAgentProcess(proc) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { proc in
            if proc.isOrphan {
                Text("PID \(String(proc.pid)) lost its parent and was re-parented to launchd. SIGTERM will be sent.")
            } else {
                Text("PID \(String(proc.pid)) is still attached to a running parent and may be in use. SIGTERM will be sent.")
            }
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
                HStack(spacing: 4) {
                    Text(proc.commandDisplay)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if proc.isOrphan {
                        badge("Orphan", tint: .orange)
                    } else if proc.tty == nil {
                        // No controlling terminal: editor-spawned agent
                        // server (e.g. Zed Agent Panel) rather than an
                        // interactive session. Orphan rows skip it — the
                        // Orphan badge already implies detachment.
                        badge("background", tint: nil)
                    }
                }
                Text(subtitle(for: proc))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(proc.workingDirectory ?? "")
            }
            Spacer(minLength: 8)
            // Native inline-remove affordance (Safari downloads style):
            // quiet gray glyph, red on hover, confirmation alert as the
            // destructive gate. Available on every row — editors keep
            // agent sessions alive after their window closes, so live
            // rows can be abandoned too.
            Button {
                killTarget = proc
                showKillAlert = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(hoveredKillPID == proc.pid ? Color.red : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                hoveredKillPID = hovering ? proc.pid : nil
            }
            .help("Kill process (SIGTERM)")
            .accessibilityLabel("Kill \(proc.commandDisplay), PID \(String(proc.pid))")
        }
    }

    /// Tiny inline status capsule sitting beside the process name. nil tint
    /// renders the quiet secondary variant ("background").
    private func badge(_ text: String, tint: Color?) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill((tint ?? Color.secondary).opacity(tint == nil ? 0.12 : 0.18)))
            .foregroundStyle(tint ?? Color.secondary)
            .fixedSize()
    }

    /// "PID 4821 · 0.2% · 02:13:45 · kwota" — the trailing project name (cwd
    /// basename) is what tells 14 look-alike claude sessions apart.
    private func subtitle(for proc: AgentProcessInfo) -> String {
        var parts = [
            "PID \(String(proc.pid))",
            "\(String(format: "%.1f", proc.cpuPercent))%",
            proc.elapsed,
        ]
        if let project = proc.projectName {
            parts.append(project)
        }
        return parts.joined(separator: " · ")
    }

    private func iconAsset(for provider: ProviderID) -> String {
        vm.registry.provider(for: provider)?.iconAssetName ?? "Mascot"
    }
}
