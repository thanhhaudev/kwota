//
//  WeekAvgCalculator.swift
//  Kwota
//
//  Pure helpers for the weekly avg reference line. Walks (at, value)
//  `sevenDay` usage samples to segment them into completed weekly cycles
//  and compute the "typical % at this elapsed point in past weeks" — the
//  same shape as `SessionAvgCalculator`, just with a 7-day window.
//
//  Without this, the pace hint compares mid-week cumulative against past
//  weeks' final peaks (e.g. "Below typical 70%" all of Mon–Wed), which
//  reads as misleading reassurance. With this, the comparison is on the
//  same axis: "where you are vs. where you usually are at this point".
//
//  No SwiftUI / Charts dependencies — testable in isolation.
//

import Foundation

enum WeekAvgCalculator {
    struct TimelineSample: Equatable {
        let elapsed: TimeInterval
        let value: Double
    }

    /// Segment a sorted (at, value) sequence into completed weekly cycles.
    ///
    /// A cycle ends when the next sample's value drops by ≥ 5.0 below the
    /// previous — within a 7d window utilization is monotonic non-decreasing,
    /// so any larger decrease implies a reset. Two groups are intentionally
    /// excluded:
    ///   - The trailing (in-progress) group, so callers don't compare against
    ///     a partial sample.
    ///   - The leading "fake first" group of samples taken before any drop
    ///     has been observed. That group's cycleStart is `samples[0].at` —
    ///     wherever the user happened to install the app — which is not a
    ///     real reset boundary. For a user installed mid-cycle near peak,
    ///     including this group would anchor "elapsed=0" at a near-100%
    ///     sample and pull `avgAtElapsed` to the chart's cap regardless of
    ///     where in the cycle the user actually is.
    ///
    /// Threshold is 5.0 (not 1.0): server-side rounding emits 1–2% jitter
    /// inside a single cycle which a 1.0 threshold misclassifies as a reset,
    /// splitting the cycle and corrupting the avg. Real weekly resets drop
    /// ~95+%, so 5.0 stays robust while ignoring rounding noise.
    static func weeklyTimelines(
        from samples: [(at: Date, value: Double)]
    ) -> [[TimelineSample]] {
        guard !samples.isEmpty else { return [] }
        var cycles: [[TimelineSample]] = []
        var current: [TimelineSample] = []
        var cycleStart: Date = samples[0].at
        var prev: Double? = nil
        var hasSeenDrop = false

        for (at, v) in samples {
            if let p = prev, v < p - 5.0 {
                if hasSeenDrop, !current.isEmpty { cycles.append(current) }
                current = []
                cycleStart = at
                hasSeenDrop = true
            }
            current.append(TimelineSample(elapsed: at.timeIntervalSince(cycleStart), value: v))
            prev = v
        }
        // Leading pre-first-drop group and trailing in-progress group are
        // both intentionally dropped — see doc-comment.
        return cycles
    }

    /// Mean of LOCF lookups across `timelines`, with an overshoot guard.
    /// For each timeline:
    ///   1. The cycle must extend at least to `target` elapsed
    ///      (`samples.last?.elapsed >= target`) — otherwise the cycle was
    ///      truncated by history retention and its captured tail is
    ///      typically near peak. Letting it LOCF would mean comparing
    ///      "where you are now" against "where past users were at
    ///      end-of-history-window," which produces the "avg line bound
    ///      to 100%" symptom for users with limited history.
    ///   2. Among qualifying cycles, take the value of the last sample
    ///      whose `elapsed ≤ target`. Cycles with no qualifying sample
    ///      contribute nothing.
    /// Returns `nil` when zero cycles contribute. `currentElapsed < 0`
    /// is treated as 0.
    static func avgAtElapsed(
        _ currentElapsed: TimeInterval,
        in timelines: [[TimelineSample]]
    ) -> Double? {
        let target = Swift.max(0, currentElapsed)
        let values: [Double] = timelines.compactMap { samples in
            guard let maxElapsed = samples.last?.elapsed, maxElapsed >= target else { return nil }
            return samples.last(where: { $0.elapsed <= target })?.value
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
