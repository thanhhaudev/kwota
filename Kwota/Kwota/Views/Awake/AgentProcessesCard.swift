//
//  AgentProcessesCard.swift
//  Kwota
//
//  "Agent Processes" section body for the Awake tab. Lists agent-related
//  processes from the VM's poll snapshot; abandoned rows (per
//  AgentProcessOrphanPolicy — ppid 1 minus detached-by-design codex helpers
//  with a live host) carry an orange badge. Every row offers Kill.
//

import SwiftUI

/// Row-visibility policy for the Agent Processes card. The popover sizes
/// itself to content (`fixedSize` in KeepAwakeTabView), so an unbounded list
/// — 14 live claude sessions is a real-world snapshot — crops the whole
/// window. The cap is TOTAL, not live-only: when a parent editor quits,
/// every session reparents to launchd at once and an orphan-exempt cap
/// would re-create the crop. Input is the VM's orphans-first sorted
/// snapshot, so orphans get priority within the cap; the rest sits behind
/// the Show-all toggle (mirroring CacheTabView's tail toggle).
enum AgentProcessListModel {
    static let collapsedCap = 5

    static func visible(_ all: [AgentProcessInfo], showAll: Bool) -> [AgentProcessInfo] {
        showAll ? all : Array(all.prefix(collapsedCap))
    }

    static func hiddenCount(_ all: [AgentProcessInfo], showAll: Bool) -> Int {
        showAll ? 0 : max(0, all.count - collapsedCap)
    }
}

/// Display strings/colors for the model's activity bucket
/// (`AgentProcessInfo.activityTier` owns the thresholds).
extension AgentProcessInfo.ActivityTier {
    var label: String {
        switch self {
        case .idle: "idle"
        case .active: "active"
        case .busy: "busy"
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .active: .green
        case .busy: .orange
        }
    }
}

/// Nontech-friendly wording for the row subtitle: "PID 4821 · ⏱ 2h 13m ·
/// ● idle" instead of raw "PID 4821 · 0.2% · 02:13:45" — a timer glyph
/// labels the duration and CPU% collapses into a colored activity dot.
enum AgentProcessRowFormat {
    /// `ps` etime ("MM:SS", "HH:MM:SS", or "D-HH:MM:SS") rendered as a
    /// human duration — "2h 13m", zero components dropped, under a minute
    /// collapses to "Just started". Unparseable input passes through
    /// unchanged so a surprise `ps` format degrades to the old raw display.
    static func durationText(etime: String) -> String {
        guard let seconds = parseETime(etime) else { return etime }
        if seconds < 60 { return "Just started" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    private static func parseETime(_ etime: String) -> Int? {
        let dayParts = etime.split(separator: "-", maxSplits: 1)
        let days: Int
        let clock: Substring
        if dayParts.count == 2 {
            guard let parsed = Int(dayParts[0]) else { return nil }
            days = parsed
            clock = dayParts[1]
        } else {
            days = 0
            clock = etime[...]
        }
        let fields = clock.split(separator: ":", omittingEmptySubsequences: false)
            .map { Int($0) }
        guard (2...3).contains(fields.count) else { return nil }
        let nums = fields.compactMap { $0 }
        guard nums.count == fields.count else { return nil }
        let (h, m, s) = nums.count == 3
            ? (nums[0], nums[1], nums[2])
            : (0, nums[0], nums[1])
        return days * 86_400 + h * 3_600 + m * 60 + s
    }
}

struct AgentProcessesCard: View {
    let vm: MenuBarViewModel

    /// Inline two-step confirm. A SwiftUI `.alert` cannot be used here: the
    /// alert window takes key status, the MenuBarExtra popover resigns key
    /// and auto-closes, and the confirmation dies with it. The confirm step
    /// therefore lives inside the row.
    @State private var confirmingKillPID: Int32?
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
        .onChange(of: vm.agentProcesses) { _, newValue in
            // The row being confirmed vanished (process exited / new scan):
            // drop the pending confirm so it can't target a reused pid.
            if let pid = confirmingKillPID,
               !newValue.contains(where: { $0.pid == pid }) {
                confirmingKillPID = nil
            }
        }
    }

    /// Collapsed: plain stack of the first `collapsedCap` rows — short.
    /// Expanded: bounded internal scroll so the popover never outgrows the
    /// screen no matter how many sessions are alive. The scroll wrapper is
    /// keyed on "actually overflowing", not the raw toggle flag, so a list
    /// that shrinks below the cap while expanded drops the extra chrome.
    @ViewBuilder
    private var rowList: some View {
        let overflowing = AgentProcessListModel.hiddenCount(vm.agentProcesses, showAll: false) > 0
        let visible = AgentProcessListModel.visible(vm.agentProcesses, showAll: showAllProcesses)
        if showAllProcesses && overflowing {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    rowStack(visible)
                }
                // Keep rows at the collapsed-state width — the bleed below
                // would otherwise stretch them into the card gutter.
                .padding(.trailing, 12)
            }
            .frame(maxHeight: expandedMaxHeight)
            // Bleed the scroll viewport into the card's trailing padding so
            // the overlay scrollbar rides the card gutter near the edge
            // instead of hovering over the kill glyphs.
            .padding(.trailing, -12)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                rowStack(visible)
            }
        }
    }

    /// Rows separated by the same hairline divider CacheTabView uses —
    /// spacing comes from per-row vertical padding so the divider sits
    /// centered between neighbours.
    @ViewBuilder
    private func rowStack(_ visible: [AgentProcessInfo]) -> some View {
        ForEach(Array(visible.enumerated()), id: \.element.id) { idx, proc in
            if idx > 0 {
                Divider().opacity(0.35)
            }
            row(proc)
                .padding(.vertical, 5)
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
        let abandoned = AgentProcessOrphanPolicy.isAbandoned(proc, in: vm.agentProcesses)
        return HStack(spacing: 8) {
            ProviderIconView(assetName: iconAsset(for: proc.provider), size: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(proc.commandDisplay)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if abandoned {
                        // Lowercase matches the sibling "background" badge
                        // and the subtitle's tier words.
                        badge("orphan", tint: .orange)
                    } else if proc.tty == nil {
                        // No controlling terminal: editor-spawned agent
                        // server (e.g. Zed Agent Panel) or a healthy
                        // detached codex helper. Abandoned rows skip it —
                        // the orphan badge already implies detachment.
                        badge("background", tint: nil)
                    }
                }
                subtitle(for: proc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if vm.killingAgentPIDs.contains(proc.pid) {
                // Kill in flight (TERM -> grace -> KILL): spinner replaces
                // the control so the row can't be re-confirmed meanwhile.
                ProgressView()
                    .controlSize(.small)
                    .help("Killing…")
            } else {
                // Native inline-remove affordance (Safari downloads style):
                // quiet gray glyph, red on hover. Available on every row —
                // editors keep agent sessions alive after their window
                // closes, so live rows can be abandoned too. The confirm is
                // an anchored bubble (KwotaConfirmPopover) shared with the
                // Cache tab — same survival trick, same look.
                Button {
                    confirmingKillPID = proc.pid
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(hoveredKillPID == proc.pid ? Color.red : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredKillPID = hovering ? proc.pid : nil
                }
                .help("Kill process (SIGTERM, then SIGKILL if ignored)")
                .accessibilityLabel("Kill \(proc.commandDisplay), PID \(String(proc.pid))")
                .popover(
                    isPresented: Binding(
                        get: { confirmingKillPID == proc.pid },
                        set: { if !$0 { confirmingKillPID = nil } }
                    ),
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .trailing
                ) {
                    KwotaConfirmPopover(
                        title: "Kill \(proc.commandDisplay)?",
                        message: confirmMessage(for: proc, abandoned: abandoned),
                        destructiveTitle: "Kill",
                        onConfirm: {
                            confirmingKillPID = nil
                            Task { await vm.killAgentProcess(proc) }
                        },
                        onCancel: { confirmingKillPID = nil }
                    )
                }
            }
        }
    }

    /// Three states, not two: abandoned (orphaned for real), detached-by-
    /// design codex helper with a live host (ppid 1 but healthy), and an
    /// ordinary row attached to a living parent.
    private func confirmMessage(for proc: AgentProcessInfo, abandoned: Bool) -> String {
        let suffix = "SIGTERM will be sent, then SIGKILL if it is ignored."
        if abandoned {
            return "PID \(String(proc.pid)) lost its parent and was re-parented to launchd. \(suffix)"
        }
        if proc.isOrphan {
            return "PID \(String(proc.pid)) is a detached helper that appears to be serving a live session in this project. \(suffix)"
        }
        return "PID \(String(proc.pid)) is still attached to a running parent and may be in use. \(suffix)"
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

    /// "# 4821 · ⏱ 2h 13m · ● idle · 📁 kwota" — every field carries a
    /// glyph (number = PID, timer = uptime, folder = project basename, the
    /// project being what tells 14 look-alike claude sessions apart).
    /// Returns concatenated `Text` so the activity dot can carry its tier
    /// color inline. Raw CPU% is intentionally not shown — the colored dot
    /// plus tier word replaces it for non-technical readability.
    private func subtitle(for proc: AgentProcessInfo) -> Text {
        let tier = proc.activityTier
        var text = inlineIcon("number")
            + Text("\(String(proc.pid)) · ")
            + inlineIcon("timer")
            + Text("\(AgentProcessRowFormat.durationText(etime: proc.elapsed)) · ")
            + Text(Image(systemName: "circle.fill"))
                // Optically center the dot on the lowercase x-height —
                // baseline-aligned it sits visibly low next to "idle".
                .font(.system(size: 6))
                .baselineOffset(1)
                .foregroundStyle(tier.color)
            + Text(" \(tier.label)")
        if let project = proc.projectName {
            text = text + Text(" · ") + inlineIcon("folder") + Text(project)
        }
        return text
    }

    /// Field glyph inside the subtitle line. Slightly under the caption2
    /// text size and nudged up half a point: full-size symbols read too
    /// heavy inline and ride high against digits (the timer glyph's crown
    /// makes it look raised at its natural baseline).
    private func inlineIcon(_ systemName: String) -> Text {
        Text(Image(systemName: systemName))
            .font(.system(size: 8.5))
            .baselineOffset(0.5)
            + Text(" ")
    }

    private func iconAsset(for provider: ProviderID) -> String {
        vm.registry.provider(for: provider)?.iconAssetName ?? "Mascot"
    }
}
