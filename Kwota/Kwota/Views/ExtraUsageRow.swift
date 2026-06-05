//
//  ExtraUsageRow.swift
//  Kwota
//

import SwiftUI

struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Extra Usage").font(.callout)
                Spacer()
                Text(headerText).font(.callout).monospacedDigit()
            }
            ProgressView(value: fraction)
                .tint(.blue)
                .accessibilityLabel("Extra usage")
                .accessibilityValue(headerText)
        }
    }

    private var headerText: String {
        if let used = extra.usedDollars, let limit = extra.limitDollars {
            let pct = extra.utilization.map { Int($0) } ?? 0
            return String(format: "$%.2f / $%.2f (%d%%)", used, limit, pct)
        }
        if let u = extra.utilization { return "\(Int(u))%" }
        return "enabled"
    }
    private var fraction: Double {
        max(0, min(1, (extra.utilization ?? 0) / 100.0))
    }
}
