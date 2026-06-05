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

    var body: some View {
        let style = MenuBarStyle.resolve(styleRaw)
        let source = MenuBarUsageSource.resolve(sourceRaw)
        let reading = MenuBarUsageDriver.read(summary: vm.summary, source: source)
        let scale = displayScale == 0 ? 2 : displayScale

        ZStack(alignment: .bottomTrailing) {
            if let img = MenuBarIconRenderer.image(
                style: style,
                reading: reading,
                colorScheme: colorScheme,
                displayScale: scale
            ) {
                Image(nsImage: img)
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
}
