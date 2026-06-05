//
//  PlanTextBadge.swift
//  Kwota
//
//  Neutral accent plan pill used by providers that don't ship a custom
//  tier-coloured badge (Claude, Codex). Renders nothing when the plan is
//  empty so a not-yet-probed profile shows no badge — matching the previous
//  inline behaviour of ProfileDetailView's header.
//

import SwiftUI

struct PlanTextBadge: View {
    let plan: String?

    var body: some View {
        if let plan, !plan.isEmpty {
            Text(plan)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                .foregroundStyle(Color.accentColor)
        }
    }
}
