import Foundation

enum CompactUsagePaceSeries {
    struct Point: Hashable {
        let at: Date
        let pace: Double
        /// Absolute burn rate (utilization %/hour) before normalization to the
        /// 24h baseline. Feeds CompactUsageStatus's time-to-cap projection.
        let burnPerHour: Double
        let segment: Int

        init(at: Date, pace: Double, burnPerHour: Double = 0, segment: Int) {
            self.at = at
            self.pace = pace
            self.burnPerHour = burnPerHour
            self.segment = segment
        }
    }

    struct Output: Equatable {
        let session: [Point]
        let week: [Point]
    }

    private struct Sample {
        let at: Date
        let utilization: Double
    }

    private struct Rate {
        let at: Date
        let raw: Double
        let duration: TimeInterval
        let segment: Int
    }

    static let defaultWindow: TimeInterval = 24 * 3600
    /// A short polling gap still describes a useful average pace. Longer
    /// gaps remain unknown so the chart does not imply activity while Kwota
    /// was not observing usage.
    static let maximumAveragedGap: TimeInterval = 3 * 3600
    static let resetJitterFloor = 1.0
    static let paceCeiling = 2.0
    static let renderBucket: TimeInterval = 30 * 60

    static func series(
        from history: [UsageHistoryEntry],
        now: Date,
        window: TimeInterval = defaultWindow
    ) -> Output {
        let cutoff = now.addingTimeInterval(-window)
        let entries = deduplicated(history).filter { $0.at <= now }

        let session = entries.compactMap { entry in
            entry.fiveHour.map { Sample(at: entry.at, utilization: $0) }
        }

        var carriedWeek: Double?
        var week: [Sample] = []
        for entry in entries {
            if let value = entry.sevenDay {
                carriedWeek = value
            }
            if let carriedWeek {
                week.append(Sample(at: entry.at, utilization: carriedWeek))
            }
        }

        return Output(
            session: buildPoints(from: visibleSamples(session, cutoff: cutoff)),
            week: buildPoints(from: visibleSamples(week, cutoff: cutoff))
        )
    }

    private static func deduplicated(
        _ history: [UsageHistoryEntry]
    ) -> [UsageHistoryEntry] {
        var byDate: [Date: UsageHistoryEntry] = [:]
        for entry in history {
            byDate[entry.at] = entry
        }
        return byDate.values.sorted { $0.at < $1.at }
    }

    private static func visibleSamples(
        _ samples: [Sample],
        cutoff: Date
    ) -> [Sample] {
        let predecessor = samples.last { $0.at < cutoff }
        let visible = samples.filter { $0.at >= cutoff }
        return predecessor.map { [$0] + visible } ?? visible
    }

    private static func buildPoints(from samples: [Sample]) -> [Point] {
        guard samples.count >= 3 else {
            return []
        }

        var rates: [Rate] = []
        var segment = 0

        for (previous, current) in zip(samples, samples.dropFirst()) {
            let elapsed = current.at.timeIntervalSince(previous.at)
            guard elapsed > 0 else {
                continue
            }

            let delta = current.utilization - previous.utilization
            if delta < -resetJitterFloor
                || (elapsed > maximumAveragedGap && delta > 0) {
                segment += 1
                continue
            }

            rates.append(Rate(
                at: current.at,
                raw: max(0, delta) / (elapsed / 3600),
                duration: elapsed,
                segment: segment
            ))
        }

        let drawableSegments = Dictionary(grouping: rates, by: \.segment)
            .filter { $0.value.count >= 2 }
        let drawableRates = rates.filter { drawableSegments[$0.segment] != nil }
        guard !drawableRates.isEmpty else {
            return []
        }

        let weightedDuration = drawableRates.reduce(0) { $0 + $1.duration }
        let weightedBurn = drawableRates.reduce(0) { $0 + $1.raw * $1.duration }
        let baseline = weightedDuration > 0 ? weightedBurn / weightedDuration : 0

        let smoothedPoints = drawableRates.enumerated().map { index, rate in
            let segmentRates = smoothingWindow(
                endingAt: index,
                in: drawableRates,
                segment: rate.segment
            )
            let duration = segmentRates.reduce(0) { $0 + $1.duration }
            let burn = segmentRates.reduce(0) { $0 + $1.raw * $1.duration }
            let smoothed = duration > 0 ? burn / duration : 0
            let normalized = baseline > 0 ? smoothed / baseline : 0

            return Point(
                at: rate.at,
                pace: min(paceCeiling, max(0, normalized)),
                burnPerHour: smoothed,
                segment: rate.segment
            )
        }

        return coalesced(points: smoothedPoints)
    }

    private static func smoothingWindow(
        endingAt index: Int,
        in rates: [Rate],
        segment: Int
    ) -> ArraySlice<Rate> {
        let segmentStart = rates[..<index].lastIndex {
            $0.segment != segment
        }.map { $0 + 1 } ?? 0
        let start = max(segmentStart, index - 4)
        return rates[start...index]
    }

    private static func coalesced(points: [Point]) -> [Point] {
        guard !points.isEmpty else {
            return []
        }

        var result: [Point] = []
        var index = 0

        while index < points.count {
            let segment = points[index].segment
            let segmentStart = points[index].at
            var buckets: [Point] = []

            while index < points.count && points[index].segment == segment {
                let bucketKey = Int(
                    points[index].at.timeIntervalSince(segmentStart) / renderBucket
                )
                var bucketPoints: [Point] = []

                while index < points.count
                    && points[index].segment == segment
                    && Int(points[index].at.timeIntervalSince(segmentStart) / renderBucket) == bucketKey {
                    bucketPoints.append(points[index])
                    index += 1
                }

                guard let lastPoint = bucketPoints.last else {
                    continue
                }

                let averagePace =
                    bucketPoints.reduce(0) { $0 + $1.pace } / Double(bucketPoints.count)
                let averageBurn =
                    bucketPoints.reduce(0) { $0 + $1.burnPerHour } / Double(bucketPoints.count)
                buckets.append(Point(
                    at: lastPoint.at,
                    pace: averagePace,
                    burnPerHour: averageBurn,
                    segment: segment
                ))
            }

            if buckets.count >= 2 {
                result.append(contentsOf: buckets)
            }
        }

        return result
    }
}
