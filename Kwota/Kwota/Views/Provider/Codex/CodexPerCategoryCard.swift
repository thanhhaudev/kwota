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
    var isCompact: Bool = false

    private let codeReviewColor: Color = .green

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let codeReviewWeekly, codeReviewWeekly.usedPercent != nil {
                if isCompact {
                    Divider()
                    CompactStatusRow(
                        label: "Code Review Weekly",
                        utilization: codeReviewWeekly.usedPercent,
                        tag: CompactUsageStatus.levelTag(utilization: codeReviewWeekly.usedPercent)
                    )
                } else {
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
}
