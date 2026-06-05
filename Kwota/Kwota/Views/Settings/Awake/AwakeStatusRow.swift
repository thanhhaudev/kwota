//
//  AwakeStatusRow.swift
//  Kwota
//

import SwiftUI

struct AwakeStatusRow: View {
    let vm: MenuBarViewModel

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var color: Color {
        switch vm.awake.state {
        case .autoActive, .manualActive: return .green
        case .batteryBlocked:            return .orange
        case .idle:                      return Color.secondary.opacity(0.5)
        }
    }

    private var title: String {
        switch vm.awake.state {
        case .autoActive:     return "Active"
        case .manualActive:   return "Active (forced)"
        case .batteryBlocked: return "Blocked"
        case .idle:           return "Idle"
        }
    }

    private var subtitle: String {
        switch vm.awake.state {
        case .autoActive:
            return "Auto keep-awake engaged"
        case .manualActive:
            return "Force keep-awake engaged"
        case .batteryBlocked:
            if let p = vm.awake.currentBatteryPercent,
               let t = vm.awake.config.batteryThreshold.percent {
                return "Battery \(p)% — below \(t)% threshold"
            }
            return "Battery below threshold"
        case .idle:
            return vm.awake.config.autoEnabled
                ? "Auto enabled — waiting for the agent"
                : "Auto disabled"
        }
    }
}
