//
//  CompactHistorySeries.swift
//  Kwota
//
//  Pure series builder behind `CompactHistoryChart`. Factored out of the view
//  so the carry-forward and segmentation rules are unit-testable without a
//  SwiftUI host — same pattern as `AntigravityUsageGroupLogic`.
//

import Foundation

enum CompactHistorySeries {
    /// One rendered sample. `remaining` is 0-100 with 100 = untouched quota —
    /// the inverse of the utilization `UsageHistoryEntry` stores. `segment`
    /// groups points into unbroken line runs and is numbered per-series, so
    /// session and week never share a segment index.
    struct Point: Hashable {
        let at: Date
        let remaining: Double
        let segment: Int
    }

    /// Compact has no range picker by design — the window is fixed.
    static let defaultWindow: TimeInterval = 24 * 3600

    /// Upward moves at or below this many percentage points are float noise,
    /// not a reset. Within a cycle utilization only accumulates, so remaining
    /// is monotonically non-increasing; any larger rise is a genuine
    /// discontinuity (a reset, or a server recalibration — which deserves the
    /// same break). `UsageHistoryEntry` stores no `resetsAt`, so the value
    /// series is the only signal available here.
    static let resetJitterFloor: Double = 1

    static func series(
        from history: [UsageHistoryEntry],
        now: Date,
        window: TimeInterval = defaultWindow
    ) -> (session: [Point], week: [Point]) {
        let sorted = history.sorted { $0.at < $1.at }
        let cutoff = now.addingTimeInterval(-window)

        // Session: every append writes fiveHour, so no carry-forward needed.
        let sessionSamples = sorted.compactMap { e in e.fiveHour.map { (e.at, $0) } }

        // Week: UsageHistoryStore.normalizedForStorage nils out sevenDay
        // whenever weekly is unchanged but fiveHour moved, so the raw column
        // is full of holes. Carry the last non-nil value forward. This runs
        // over the FULL history before windowing — the first entry inside the
        // window may owe its value to a sample that predates the cutoff.
        var carried: Double?
        var weekSamples: [(Date, Double)] = []
        for e in sorted {
            if let v = e.sevenDay { carried = v }
            if let c = carried { weekSamples.append((e.at, c)) }
        }

        return (
            session: segmented(sessionSamples.filter { $0.0 >= cutoff }),
            week:    segmented(weekSamples.filter { $0.0 >= cutoff })
        )
    }

    private static func segmented(_ samples: [(Date, Double)]) -> [Point] {
        var out: [Point] = []
        var segment = 0
        var previous: Double?
        for (at, utilization) in samples {
            let remaining = max(0, min(100, 100 - utilization))
            if let previous, remaining - previous > resetJitterFloor { segment += 1 }
            out.append(Point(at: at, remaining: remaining, segment: segment))
            previous = remaining
        }
        return out
    }
}
