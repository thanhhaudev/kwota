//
//  CodexPerCategoryCard.swift
//  Kwota
//
//  Vertical list of Codex-specific secondary categories (Code Review
//  Weekly; future Spark). Rows are the shared `UsageBatteryRow`, same as
//  Claude's PerModelCard. Hidden when all rows would be empty.
//

import SwiftUI

struct CodexPerCategoryCard: View {
    let codeReviewWeekly: CodexUsageSnapshot.Window?

    private let codeReviewColor: Color = .green

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let codeReviewWeekly, codeReviewWeekly.usedPercent != nil {
                UsageBatteryRow(
                    label: "Code Review Weekly",
                    utilization: codeReviewWeekly.usedPercent,
                    color: codeReviewColor,
                    labelWidth: 130
                )
            }
        }
    }
}
