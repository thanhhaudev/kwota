//
//  SessionAvgCalculator.swift
//  Kwota
//
//  Pure helpers for the session avg reference line. Walks (at, value) usage
//  samples to segment them into completed session cycles and compute the
//  "typical % at this elapsed time" for the live chart's `avg` line.
//
//  No SwiftUI / Charts dependencies — testable in isolation.
//

import Foundation

enum SessionAvgCalculator {
    struct TimelineSample: Equatable {
        let elapsed: TimeInterval
        let value: Double
    }

    /// Segment a sorted (at, value) sequence into completed session cycles.
    ///
    /// A cycle ends when the next sample's value drops by ≥ 5.0 below the
    /// previous — within a 5h window utilization is monotonic non-decreasing,
    /// so any larger decrease implies a reset. The trailing (in-progress)
    /// cycle is excluded so callers don't compare against a partial sample.
    ///
    /// Threshold is 5.0 (not 1.0): server-side rounding emits 1–2% jitter
    /// inside a single cycle which a 1.0 threshold misclassifies as a reset,
    /// splitting the cycle and corrupting the avg. Real session resets drop
    /// ~95+% (e.g. 95 → 0), so 5.0 keeps detection robust while ignoring
    /// rounding noise.
    ///
    /// Each emitted cycle is `[TimelineSample]` where `elapsed` is measured
    /// from the cycle's first sample.
    static func sessionTimelines(
        from samples: [(at: Date, value: Double)]
    ) -> [[TimelineSample]] {
        guard !samples.isEmpty else { return [] }
        var cycles: [[TimelineSample]] = []
        var current: [TimelineSample] = []
        var cycleStart: Date = samples[0].at
        var prev: Double? = nil

        for (at, v) in samples {
            if let p = prev, v < p - 5.0 {
                // Reset: close out the just-finished cycle, start a new one.
                if !current.isEmpty { cycles.append(current) }
                current = []
                cycleStart = at
            }
            current.append(TimelineSample(elapsed: at.timeIntervalSince(cycleStart), value: v))
            prev = v
        }
        // Trailing `current` is the in-progress cycle — intentionally dropped.
        return cycles
    }

    /// Mean of LOCF lookups across `timelines`.
    ///
    /// For each timeline, take the value of the **last** sample whose
    /// `elapsed ≤ currentElapsed`. Cycles with no qualifying sample (e.g.
    /// empty timeline) contribute nothing. Returns `nil` when zero cycles
    /// contribute.
    ///
    /// `currentElapsed < 0` is treated as 0 (defensive against clock skew).
    static func avgAtElapsed(
        _ currentElapsed: TimeInterval,
        in timelines: [[TimelineSample]]
    ) -> Double? {
        let target = Swift.max(0, currentElapsed)
        let values: [Double] = timelines.compactMap { samples in
            samples.last(where: { $0.elapsed <= target })?.value
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
