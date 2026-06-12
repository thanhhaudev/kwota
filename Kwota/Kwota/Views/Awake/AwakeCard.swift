//
//  AwakeCard.swift
//  Kwota
//

import SwiftUI

// MARK: - Pure copy helpers

enum AwakeCardCopy {
    enum BodyKind: Equatable {
        case startControls
        case stop
        case batteryBlocked
        case empty
    }

    static func title(state: AwakeState, autoEnabled: Bool) -> String {
        switch state {
        case .idle:
            return autoEnabled ? "Standby" : "Ready"
        case .autoActive:
            return "Auto awake"
        case .manualActive:
            return "Manual awake"
        case .batteryBlocked:
            return "Paused"
        }
    }

    static func subtitle(
        state: AwakeState,
        autoEnabled: Bool,
        now: Date,
        lastActivity: Date?,
        batteryPct: Int?,
        batteryThreshold: Int?,
        activeProviderNames: [String] = [],
        userIdleGateEnabled: Bool = false
    ) -> String {
        switch state {
        case .idle:
            if autoEnabled {
                // When the gate is on and the agent is still active (pulsed
                // within the keep-awake window), the real blocker is user
                // presence — tell the user what to expect.
                if userIdleGateEnabled,
                   let last = lastActivity,
                   now.timeIntervalSince(last) < 5 * 60 {
                    return "Agent active — keeps your Mac awake once you step away"
                }
                return "Waiting for agent activity"
            }
            return ""

        case .autoActive(let since):
            let suffix: String
            if let last = lastActivity,
               now.timeIntervalSince(last) < 5 * 60 {
                suffix = "last activity \(formatRelative(now.timeIntervalSince(last)))"
            } else {
                suffix = "active since \(formatClock(since))"
            }
            if !activeProviderNames.isEmpty {
                let verb = activeProviderNames.count == 1 ? "is" : "are"
                return "\(joinNames(activeProviderNames)) \(verb) working · \(suffix)"
            }
            // No provider attribution: capitalize the first letter of the suffix.
            return suffix.isEmpty ? suffix : suffix.prefix(1).uppercased() + suffix.dropFirst()

        case .manualActive(_, .none):
            return "No auto-stop"

        case .manualActive(let since, .some(let timeout)):
            let remaining = max(0, timeout - now.timeIntervalSince(since))
            let countdown = AwakeFormatters.formatHMS(Int(remaining))
            return "\(countdown) left"

        case .batteryBlocked:
            if let pct = batteryPct, let thresh = batteryThreshold {
                return "Battery \(pct)% (below \(thresh)% threshold)"
            }
            return "Battery below threshold"
        }
    }

    static func bodyKind(state: AwakeState, autoEnabled: Bool) -> BodyKind {
        switch state {
        case .idle:
            return autoEnabled ? .empty : .startControls
        case .autoActive:
            return .empty
        case .manualActive:
            return .stop
        case .batteryBlocked:
            return .batteryBlocked
        }
    }

    // MARK: Formatters

    /// Joins provider names with commas and a trailing "and":
    /// `[A]` → "A", `[A, B]` → "A and B", `[A, B, C]` → "A, B and C".
    private static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0:  return ""
        case 1:  return names[0]
        case 2:  return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    private static func formatClock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private static func formatRelative(_ seconds: TimeInterval) -> String {
        let i = max(0, Int(seconds))
        if i < 60 { return "just now" }
        return "\(i / 60)m ago"
    }
}

// MARK: - Card view

struct AwakeCard: View {
    let vm: MenuBarViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse: Bool = false
    @State private var showInfo: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !isBodyEmpty {
                Divider()
                body(for: bodyKind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kwotaCard()
        .onAppear { pulse = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            statusDot.padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                subtitleArea
            }
            Spacer(minLength: 0)
            infoButton
        }
    }

    private var subtitleArea: some View {
        TimelineView(.periodic(from: .now, by: subtitleTickInterval)) { ctx in
            let text = subtitle(now: ctx.date)
            if !text.isEmpty {
                HStack(spacing: 4) {
                    if showTimerIcon {
                        Image(systemName: "timer")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var showTimerIcon: Bool {
        switch vm.awake.state {
        case .manualActive, .autoActive: return true
        default:                         return false
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch vm.awake.state {
        case .idle:
            if vm.awake.config.autoEnabled { pulsingDot(.blue) }
            else { staticDot(Color.secondary.opacity(0.5)) }
        case .autoActive:     staticDot(.green)
        case .manualActive:   staticDot(Color("AwakeManual"))
        case .batteryBlocked: staticDot(.orange)
        }
    }

    private func staticDot(_ color: Color) -> some View {
        Circle().fill(color.gradient).frame(width: 10, height: 10)
    }

    private func pulsingDot(_ color: Color) -> some View {
        Circle()
            .fill(color.gradient)
            .frame(width: 10, height: 10)
            .opacity(reduceMotion ? 0.85 : (pulse ? 1.0 : 0.4))
            .animation(
                reduceMotion ? nil
                             : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                value: pulse
            )
    }

    private var infoButton: some View {
        Button { showInfo.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About awake modes")
        .accessibilityHint("Opens help about auto and manual awake modes")
        .popover(isPresented: $showInfo, arrowEdge: .top) {
            infoPopoverContent
        }
    }

    private var infoPopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            infoSection(
                heading: "Auto mode",
                body: "Tails your AI agents' logs and keeps your Mac awake while an agent is working. Starts once you've been away from the keyboard, and stops after the agent goes idle or when you return — configure both in Settings → Awake."
            )
            Divider()
            infoSection(
                heading: "Manual mode",
                body: "Forces awake for a chosen duration regardless of agent activity."
            )
            Divider()
            infoSection(
                heading: nil,
                body: "Battery threshold, idle window, and away threshold live in Settings → Awake."
            )
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    private func infoSection(heading: String?, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let heading {
                Text(heading)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    // MARK: Body dispatch

    private var bodyKind: AwakeCardCopy.BodyKind {
        AwakeCardCopy.bodyKind(
            state: vm.awake.state,
            autoEnabled: vm.awake.config.autoEnabled
        )
    }

    private var isBodyEmpty: Bool { bodyKind == .empty }

    @ViewBuilder
    private func body(for kind: AwakeCardCopy.BodyKind) -> some View {
        switch kind {
        case .startControls:
            startControlsBody
        case .stop:
            stopBody
        case .batteryBlocked:
            batteryBlockedBody
        case .empty:
            EmptyView()
        }
    }

    private var startControlsBody: some View {
        VStack(spacing: 8) {
            Button {
                _ = vm.awakeForceStart()
            } label: {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(ThreeDCircleButtonStyle(tint: Color("AwakeManual"), enabled: canStartForce))
            .disabled(!canStartForce)
            .accessibilityLabel("Keep Mac awake")
            .help("Keep Mac awake")
            HStack(spacing: 4) {
                Text("for")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CompactInlinePicker(
                    selection: Binding(
                        get: { vm.awake.config.forceTimeout },
                        set: { vm.awake.updateForceTimeout($0) }
                    ),
                    options: TimeoutChoice.allCases,
                    title: { $0.label },
                    compact: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var stopBody: some View {
        if case .manualActive = vm.awake.state {
            Button {
                vm.awakeForceStop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(ThreeDCircleButtonStyle(tint: Self.stopTint, enabled: true))
            .accessibilityLabel("Stop manual awake")
            .help("Stop manual awake")
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private static let stopTint = Color.gray

    private var batteryBlockedBody: some View {
        let thresh = vm.awake.config.batteryThreshold.percent.map { "\($0)%" } ?? "the threshold"
        return Text("Auto-awake will resume when battery exceeds \(thresh) or you plug in.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Helpers

    private var title: String {
        AwakeCardCopy.title(
            state: vm.awake.state,
            autoEnabled: vm.awake.config.autoEnabled
        )
    }

    private func subtitle(now: Date) -> String {
        AwakeCardCopy.subtitle(
            state: vm.awake.state,
            autoEnabled: vm.awake.config.autoEnabled,
            now: now,
            lastActivity: vm.awake.lastJSONLActivity,
            batteryPct: vm.awake.currentBatteryPercent,
            batteryThreshold: vm.awake.config.batteryThreshold.percent,
            activeProviderNames: activeProviderNames(now: now),
            userIdleGateEnabled: vm.awake.config.userIdleGate != .off
        )
    }

    /// Providers with agent activity in the last 5 minutes (the keep-awake
    /// window), in stable order and capped at 3 — so the subtitle attributes
    /// every agent working at once, matching the chart's active set. Falls back
    /// to the single last-active provider when the historian has no recent
    /// agent-response event yet (keep-awake is driven by file writes, which can
    /// lead the first charted reply).
    private func activeProviderNames(now: Date) -> [String] {
        let window: TimeInterval = 5 * 60
        let recent = vm.activityHistorian.activeProviders(in: now.addingTimeInterval(-window)...now)
        let names = recent.prefix(3).compactMap { vm.registry.provider(for: $0)?.displayName }
        if !names.isEmpty { return names }
        return vm.awake.lastActiveProvider
            .flatMap { vm.registry.provider(for: $0)?.displayName }
            .map { [$0] } ?? []
    }

    private var canStartForce: Bool {
        if case .batteryBlocked = vm.awake.state { return false }
        return vm.awake.config.flags.hasAnyFlag
    }

    private var subtitleTickInterval: TimeInterval {
        if case .manualActive(_, let timeout) = vm.awake.state, timeout != nil {
            return 1
        }
        return 30
    }
}

// MARK: - 3D circle button style

struct ThreeDCircleButtonStyle: ButtonStyle {
    let tint: Color
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 48, height: 48)
            .background(
                Circle()
                    .fill(enabled ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.secondary.gradient))
            )
            .overlay(
                Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(
                color: .black.opacity(enabled ? 0.25 : 0.12),
                radius: configuration.isPressed ? 2 : 4,
                y: configuration.isPressed ? 1 : 2
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
