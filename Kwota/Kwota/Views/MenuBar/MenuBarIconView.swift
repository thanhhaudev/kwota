//
//  MenuBarIconView.swift
//  Kwota
//

import SwiftUI

struct MenuBarIconView: View {
    let vm: MenuBarViewModel

    @AppStorage(AppStorageKeys.generalMenuBarStyle) private var styleRaw: String = MenuBarStyle.original.rawValue
    @AppStorage(AppStorageKeys.generalMenuBarUsageSource) private var sourceRaw: String = MenuBarUsageSource.session.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    @State private var pulseOpacity: Double = 1.0

    private static let pulseAnimation: Animation =
        .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    private static let pulseStopAnimation: Animation =
        .easeInOut(duration: 0.3)
    private static let pulseMinOpacity: Double = 0.55

    var body: some View {
        let style = MenuBarStyle.resolve(styleRaw)
        let source = MenuBarUsageSource.resolve(sourceRaw)
        let reading = MenuBarUsageDriver.read(summary: vm.summary, source: source)
        let scale = displayScale == 0 ? 2 : displayScale
        let shouldPulse = MenuBarPulse.shouldPulse(style: style, utilization: reading.utilization)

        ZStack(alignment: .bottomTrailing) {
            if let img = MenuBarIconRenderer.image(
                style: style,
                reading: reading,
                colorScheme: colorScheme,
                displayScale: scale
            ) {
                Image(nsImage: img)
                    .opacity(pulseOpacity)
                    .onAppear { applyPulse(shouldPulse) }
                    .onChange(of: shouldPulse) { _, newValue in applyPulse(newValue) }
            } else {
                // ImageRenderer failure is extreme (OOM); keep the slot
                // alive with a SF symbol so the user can still click in.
                Image(systemName: "circle")
                    .renderingMode(.template)
                    .onAppear {
                        AppLog.shared.log("MenuBarIcon render returned nil", level: .error)
                    }
            }

            if let dot = badgeColor {
                Circle()
                    .fill(dot)
                    .frame(width: 4, height: 4)
                    .offset(x: 1, y: 1)
                    .accessibilityHidden(true)
            }
        }
    }

    private var badgeColor: Color? {
        switch vm.awake.state {
        case .autoActive, .manualActive: return .green
        case .batteryBlocked:            return .orange
        case .idle:                      return nil
        }
    }

    private func applyPulse(_ active: Bool) {
        if active {
            pulseOpacity = 1.0
            withAnimation(Self.pulseAnimation) {
                pulseOpacity = Self.pulseMinOpacity
            }
        } else {
            withAnimation(Self.pulseStopAnimation) {
                pulseOpacity = 1.0
            }
        }
    }
}
