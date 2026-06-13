//
//  AntigravityGroupHistoryBuilder.swift
//  Kwota
//
//  Pure mapping from a quota summary to one UsageHistoryEntry per group, so
//  each group's Session(5h)/Weekly trend can be charted independently. The
//  5h utilization lands in `fiveHour` and the weekly in `sevenDay`, matching
//  UsageTrendChart's session/weekly slots.
//

import Foundation

enum AntigravityGroupHistoryBuilder {
    static func entries(
        from quota: AntigravityQuotaSummary,
        at: Date
    ) -> [(key: String, entry: UsageHistoryEntry)] {
        quota.groups.map { group in
            (key: group.key,
             entry: UsageHistoryEntry(
                at: at,
                fiveHour: group.fiveHour?.utilization,
                sevenDay: group.weekly?.utilization))
        }
    }
}
