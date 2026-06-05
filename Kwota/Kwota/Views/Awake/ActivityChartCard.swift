//
//  ActivityChartCard.swift
//  Kwota
//

import SwiftUI
import Charts

struct ActivityChartCard: View {
    let vm: MenuBarViewModel

    @Environment(\.displayScale) private var displayScale

    private static let bucketSeconds: TimeInterval = 5 * 60   // 5-min buckets → 96 per 8h, 288 at 24h max
    /// Multi-wave y-domain ceiling: a hair above 1.0 so normalized peaks have
    /// headroom under the legend instead of touching the plot's top edge.
    static let multiWaveYTop: Double = 1.1
    private static let autoBandColor: Color = .green
    private static let manualBandColor: Color = Color("AwakeManual")

    static func bandColor(for mode: AwakeSession.Mode) -> Color {
        switch mode {
        case .auto:   return autoBandColor
        case .manual: return manualBandColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            chartContent
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kwotaCard()
    }

    // MARK: - Chart

    private var chartContent: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let now = ctx.date
            let window = Self.displayWindow(now: now, sessions: vm.awakeSessionLog.sessions)
            let windowStart = now.addingTimeInterval(-window)
            let awakeIntervals = Self.awakeIntervals(
                sessions: vm.awakeSessionLog.sessions,
                windowStart: windowStart,
                now: now
            )
            let active = vm.activityHistorian.activeProviders(in: windowStart...now)

            if Self.usesMultiWave(activeCount: active.count) {
                // No outer height clamp here: `multiWaveChart` sizes the plot
                // itself (72pt, matching single mode) and lets the legend sit
                // above it, so the legend never eats into the wave's height.
                multiWaveChart(
                    active: active,
                    awakeIntervals: awakeIntervals,
                    windowStart: windowStart,
                    now: now,
                    window: window
                )
            } else {
                // 0 or 1 active provider → the absolute single wave, sourced
                // from the SOLE active provider's timestamps (defaults to
                // `.claude` for an empty/legacy window so the hue is stable).
                let provider = active.first ?? .claude
                let buckets = Self.eventBuckets(
                    timestamps: vm.activityHistorian.timestamps(for: provider),
                    windowStart: windowStart,
                    now: now,
                    bucketSize: Self.bucketSeconds
                )
                let yMax = Self.computeYMax(buckets: buckets)
                chart(
                    buckets: buckets,
                    yMax: yMax,
                    awakeIntervals: awakeIntervals,
                    windowStart: windowStart,
                    now: now,
                    window: window,
                    color: ProviderPalette.color(for: provider)
                )
                .frame(height: 72)
            }
        }
    }

    private func chart(
        buckets: [EventBucket],
        yMax: Int,
        awakeIntervals: [AwakeInterval],
        windowStart: Date,
        now: Date,
        window: TimeInterval,
        color: Color
    ) -> some View {
        let active = vm.activityHistorian.activeProviders(in: windowStart...now)
        let stats = Self.windowStats(
            sessions: vm.awakeSessionLog.sessions,
            providerTimestamps: active.map {
                (provider: $0, timestamps: vm.activityHistorian.timestamps(for: $0))
            },
            windowStart: windowStart,
            now: now
        )
        return chartBody(
            buckets: buckets,
            yMax: yMax,
            awakeIntervals: awakeIntervals,
            windowStart: windowStart,
            now: now,
            window: window,
            color: color
        )
        // VoiceOver: collapse all per-mark detail into one summary read.
        // A 96-bucket chart with per-bucket labels would spam the screen
        // reader; the glance-level fact a user needs is "did Claude work
        // and was the Mac awake during the past N hours".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recent agent activity, past \(Int(window / 3600)) hours")
        .accessibilityValue(Self.chartAccessibilityValue(stats: stats, window: window))
    }

    private func chartBody(
        buckets: [EventBucket],
        yMax: Int,
        awakeIntervals: [AwakeInterval],
        windowStart: Date,
        now: Date,
        window: TimeInterval,
        color: Color
    ) -> some View {
        // Single chart owns axis + wave so the plot frame is shared. A dual
        // chart ZStack diverged plot frames — `chartXAxis(.hidden)` on the
        // wave layer let it bleed into the label gutter, painting curves on
        // top of the hour ticks.
        Chart {
            // Ambient awake-state tint: faint vertical band across the plot
            // for each awake interval clipped to the visible window. Declared
            // first so it renders BEHIND the wave + baseline. Auto sessions
            // tint green to match the response wave; manual sessions tint
            // orange to match the manual status dot and start button.
            ForEach(awakeIntervals) { interval in
                RectangleMark(
                    xStart: .value("Awake start", interval.start),
                    xEnd: .value("Awake end", interval.end),
                    yStart: .value("YS", 0),
                    yEnd: .value("YE", Double(yMax))
                )
                .foregroundStyle(Self.bandColor(for: interval.mode).opacity(0.08))
            }

            // Baseline rule. Spans the full window even when buckets are all
            // zero, so the time domain stays visible in idle stretches.
            RuleMark(y: .value("Baseline", 0))
                .foregroundStyle(Color.secondary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 0.5))

            // Continuous wave: one AreaMark+LineMark per bucket, no series
            // split. Idle stretches show as a flat line on the baseline.
            ForEach(buckets) { b in
                // Cap displayed count at yMax so outlier bursts render as
                // a flat plateau at the chart's top edge rather than
                // clipping with a hard cut above the plot frame.
                let displayCount = min(b.count, yMax)
                AreaMark(
                    x: .value("Time", b.start),
                    y: .value("Events", displayCount)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.55), color.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", b.start),
                    y: .value("Events", displayCount)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: windowStart...now)
        .chartYScale(domain: 0...Double(yMax))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: Self.hourMarks(window: window).map {
                now.addingTimeInterval($0 * 3600)
            }) { value in
                // Skip the gridline + tick at the rightmost "now" position so
                // the chart reads as an open-ended stream of incoming data —
                // same convention the session chart uses on its leading edge.
                // The "now" label still renders (it's just the vertical track
                // through the plot area that's dropped).
                let isNow: Bool = {
                    guard let date = value.as(Date.self) else { return false }
                    return abs(date.timeIntervalSince(now)) < 60
                }()
                if !isNow {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                    AxisTick(length: .longestLabel,
                             stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                }
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(xAxisLabel(for: date, now: now))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(height: 1 / displayScale)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(height: 1 / displayScale)
                }
        }
    }

    // MARK: - Multi-provider wave

    private func multiWaveChart(
        active: [ProviderID],
        awakeIntervals: [AwakeInterval],
        windowStart: Date,
        now: Date,
        window: TimeInterval
    ) -> some View {
        let timestampsByProvider = active.map { vm.activityHistorian.timestamps(for: $0) }
        let sharedMax = Self.sharedMaxCount(
            providerTimestamps: timestampsByProvider,
            windowStart: windowStart, now: now, bucketSize: Self.bucketSeconds)
        return VStack(alignment: .leading, spacing: 4) {
            legend(for: active)
            Chart {
                ForEach(awakeIntervals) { interval in
                    RectangleMark(
                        xStart: .value("Awake start", interval.start),
                        xEnd: .value("Awake end", interval.end),
                        yStart: .value("YS", 0.0),
                        yEnd: .value("YE", Self.multiWaveYTop)
                    )
                    .foregroundStyle(Self.bandColor(for: interval.mode).opacity(0.08))
                }
                RuleMark(y: .value("Baseline", 0.0))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))

                ForEach(active, id: \.self) { provider in
                    let color = ProviderPalette.color(for: provider)
                    let points = Self.normalizedWave(
                        timestamps: vm.activityHistorian.timestamps(for: provider),
                        windowStart: windowStart, now: now, bucketSize: Self.bucketSeconds,
                        maxCount: sharedMax)
                    ForEach(points) { p in
                        AreaMark(
                            x: .value("Time", p.start),
                            y: .value("Activity", p.value),
                            series: .value("Provider", provider.rawValue),
                            // Overlapping translucent fills, NOT stacked. Default
                            // `.standard` stacking pile each provider's area on the
                            // previous one's, so the 2nd+ provider's tint floats
                            // above its own (unstacked) line instead of filling
                            // from the baseline. `.unstacked` makes every fill run
                            // baseline → its value, hugging its line.
                            stacking: .unstacked
                        )
                        .foregroundStyle(color.opacity(0.18))
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("Time", p.start),
                            y: .value("Activity", p.value),
                            series: .value("Provider", provider.rawValue)
                        )
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                        .interpolationMethod(.monotone)
                    }
                }
            }
            .chartXScale(domain: windowStart...now)
            // Domain tops out a touch above 1.0 so a fully-normalized peak
            // (value 1.0) lands just below the plot's top edge instead of
            // touching it / crowding the legend above.
            .chartYScale(domain: 0.0...Self.multiWaveYTop)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: Self.hourMarks(window: window).map {
                    now.addingTimeInterval($0 * 3600)
                }) { value in
                    let isNow: Bool = {
                        guard let date = value.as(Date.self) else { return false }
                        return abs(date.timeIntervalSince(now)) < 60
                    }()
                    if !isNow {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                        AxisTick(length: .longestLabel,
                                 stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                    }
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(xAxisLabel(for: date, now: now))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // Plot owns its height (matches single mode); the legend sits above
            // it in the VStack rather than sharing one squashed 72pt frame.
            .frame(height: 72)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recent agent activity by provider, past \(Int(window / 3600)) hours")
        .accessibilityValue(active.map { Self.providerDisplayName($0) }.joined(separator: ", "))
    }

    private func legend(for providers: [ProviderID]) -> some View {
        HStack(spacing: 10) {
            ForEach(providers, id: \.self) { provider in
                HStack(spacing: 4) {
                    Circle()
                        .fill(ProviderPalette.color(for: provider))
                        .frame(width: 7, height: 7)
                    Text(Self.providerDisplayName(provider))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    static func providerDisplayName(_ provider: ProviderID) -> String {
        switch provider {
        case .claude:      return "Claude"
        case .codex:       return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    // MARK: - Display window

    /// Computes the chart's displayed window. Defaults to 8h; extends when an
    /// awake session is still open and started more than 8h ago; clamps at
    /// 24h. Pure function — recomputed on every TimelineView tick.
    ///
    /// Decoupled from the services' retention window (fixed 24h): the view
    /// asks for the latest window's worth of data from the same 24h ring
    /// buffer that always lives in memory.
    static func displayWindow(now: Date, sessions: [AwakeSession]) -> TimeInterval {
        let defaultWindow: TimeInterval = 8 * 3600
        let maxWindow: TimeInterval = 24 * 3600
        let openStarts = sessions.compactMap { session -> Date? in
            session.end == nil ? session.start : nil
        }
        guard let oldestOpen = openStarts.min() else { return defaultWindow }
        let elapsed = now.timeIntervalSince(oldestOpen)
        guard elapsed > defaultWindow else { return defaultWindow }
        return min(elapsed, maxWindow)
    }

    /// Tick spacing for the x-axis. Adapts to the window so labels stay
    /// readable: 2h for short windows, 4h for half-day, 6h for full-day.
    static func tickInterval(window: TimeInterval) -> TimeInterval {
        let hours = window / 3600
        if hours <= 8 { return 2 * 3600 }
        if hours <= 16 { return 4 * 3600 }
        return 6 * 3600
    }

    /// Negative hour offsets (e.g. -8, -6, -4, -2 for 8h window). The view
    /// composes Dates with `now.addingTimeInterval($0 * 3600)`. Includes the
    /// leftmost edge mark so the window boundary always has a label, omits
    /// the rightmost `0` (now) — that convention is handled in the axis
    /// renderer.
    static func hourMarks(window: TimeInterval) -> [Double] {
        let intervalHours = tickInterval(window: window) / 3600
        let windowHours = window / 3600
        var marks: [Double] = []
        var h = intervalHours
        while h <= windowHours {
            marks.append(-h)
            h += intervalHours
        }
        return marks.reversed()
    }

    // MARK: - Bucket derivation

    struct EventBucket: Identifiable {
        let id = UUID()
        let start: Date
        let count: Int
    }

    /// A bucket's count rescaled to a shared max (0…1). All providers share one
    /// denominator so overlaid waves compare by real volume — a low-volume
    /// provider draws proportionally short rather than filling the plot.
    struct NormalizedPoint: Identifiable {
        let id = UUID()
        let start: Date
        let value: Double
    }

    static func normalizedWave(
        timestamps: [Date], windowStart: Date, now: Date, bucketSize: TimeInterval, maxCount: Int
    ) -> [NormalizedPoint] {
        let buckets = eventBuckets(
            timestamps: timestamps, windowStart: windowStart, now: now, bucketSize: bucketSize)
        guard maxCount > 0 else {
            return buckets.map { NormalizedPoint(start: $0.start, value: 0) }
        }
        return buckets.map {
            NormalizedPoint(start: $0.start, value: Double($0.count) / Double(maxCount))
        }
    }

    /// The largest single-bucket count across every provider in the window — the
    /// shared denominator for `normalizedWave` in multi-wave mode. 0 when no
    /// provider has any in-window events.
    static func sharedMaxCount(
        providerTimestamps: [[Date]], windowStart: Date, now: Date, bucketSize: TimeInterval
    ) -> Int {
        providerTimestamps.map { ts in
            eventBuckets(timestamps: ts, windowStart: windowStart, now: now, bucketSize: bucketSize)
                .map(\.count).max() ?? 0
        }.max() ?? 0
    }

    /// ≥2 active providers in the window → overlaid per-provider waves + legend;
    /// otherwise the single absolute wave.
    static func usesMultiWave(activeCount: Int) -> Bool { activeCount >= 2 }

    /// One awake session clipped to the visible window. Mode is preserved on
    /// the type for future use (e.g., differentiating auto/manual tint) but
    /// the current render uses a single hue for both.
    struct AwakeInterval: Identifiable {
        let id: UUID
        let mode: AwakeSession.Mode
        let start: Date
        let end: Date
    }

    /// Filter + clip awake sessions to `[windowStart, now]`. Ongoing sessions
    /// clamp their end to `now`; sessions ending before the window are
    /// dropped. Returns in original log order (chronological).
    static func awakeIntervals(
        sessions: [AwakeSession],
        windowStart: Date,
        now: Date
    ) -> [AwakeInterval] {
        sessions.compactMap { session in
            let endRaw = session.end ?? now
            guard endRaw >= windowStart else { return nil }
            let start = max(session.start, windowStart)
            let end = min(endRaw, now)
            guard start < end else { return nil }
            return AwakeInterval(id: session.id, mode: session.mode, start: start, end: end)
        }
    }

    /// Robust Y-axis ceiling for the wave. Without this, one outlier
    /// bucket (e.g., a 30-event agentic burst) would set yMax and squash
    /// every normal hump down onto the baseline.
    ///
    /// Strategy: use the 75th-percentile of non-zero buckets and allow up
    /// to 2× headroom above it. Anything taller than that ceiling clips at
    /// the top (which the wave renderer handles by capping displayCount).
    /// With fewer than 4 non-zero buckets the distribution isn't
    /// meaningful, so we fall back to the raw max — the chart is small
    /// enough that "one event" still renders visibly at any sensible
    /// floor.
    static func computeYMax(buckets: [EventBucket]) -> Int {
        let nonZero = buckets.map(\.count).filter { $0 > 0 }
        guard let rawMax = nonZero.max() else { return 1 }
        guard nonZero.count >= 4 else { return max(1, rawMax) }
        let sorted = nonZero.sorted()
        let p75 = sorted[Int(Double(sorted.count) * 0.75)]
        let cap = max(1, p75 * 2)
        return min(rawMax, cap)
    }

    /// Dense, time-aligned buckets covering `[windowStart, now]`. Zero-count
    /// buckets are emitted so the wave's interpolation crosses idle stretches
    /// at the baseline rather than gap-jumping.
    static func eventBuckets(
        timestamps: [Date],
        windowStart: Date,
        now: Date,
        bucketSize: TimeInterval
    ) -> [EventBucket] {
        guard windowStart < now, bucketSize > 0 else { return [] }
        let total = now.timeIntervalSince(windowStart)
        let n = Int((total / bucketSize).rounded(.up))
        guard n > 0 else { return [] }

        // Timestamps arrive sorted; advance a single index across buckets to
        // keep this O(buckets + events) instead of O(buckets × events).
        var out: [EventBucket] = []
        out.reserveCapacity(n)
        var i = timestamps.firstIndex { $0 >= windowStart } ?? timestamps.endIndex
        for k in 0..<n {
            let bStart = windowStart.addingTimeInterval(Double(k) * bucketSize)
            let bEnd = bStart.addingTimeInterval(bucketSize)
            var count = 0
            while i < timestamps.endIndex, timestamps[i] < bEnd {
                count += 1
                i += 1
            }
            out.append(EventBucket(start: bStart, count: count))
        }
        return out
    }

    private func xAxisLabel(for date: Date, now: Date) -> String {
        let h = Int(now.timeIntervalSince(date) / 3600.0)
        return h == 0 ? "now" : "-\(h)h"
    }

    // MARK: - Footer

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let now = ctx.date
            let window = Self.displayWindow(now: now, sessions: vm.awakeSessionLog.sessions)
            let windowStart = now.addingTimeInterval(-window)
            let active = vm.activityHistorian.activeProviders(in: windowStart...now)
            let stats = Self.windowStats(
                sessions: vm.awakeSessionLog.sessions,
                providerTimestamps: active.map {
                    (provider: $0, timestamps: vm.activityHistorian.timestamps(for: $0))
                },
                windowStart: windowStart,
                now: now
            )
            Text(Self.footerText(stats: stats, window: window))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// In-window activity-event count for one provider.
    struct ProviderCount: Equatable {
        let provider: ProviderID
        let count: Int
    }

    /// Aggregate counters for the visible window. Awake time is split by mode;
    /// activity is split by provider (only providers with > 0 in-window events,
    /// in stable order [.claude, .codex, .antigravity]).
    struct WindowStats {
        let awakeAuto: TimeInterval
        let awakeManual: TimeInterval
        let providerCounts: [ProviderCount]
        var totalAwake: TimeInterval { awakeAuto + awakeManual }
    }

    static func windowStats(
        sessions: [AwakeSession],
        providerTimestamps: [(provider: ProviderID, timestamps: [Date])],
        windowStart: Date,
        now: Date
    ) -> WindowStats {
        var auto: TimeInterval = 0
        var manual: TimeInterval = 0
        for session in sessions {
            let endRaw = session.end ?? now
            guard endRaw >= windowStart else { continue }
            let start = max(session.start, windowStart)
            let end = min(endRaw, now)
            guard start < end else { continue }
            let dur = end.timeIntervalSince(start)
            switch session.mode {
            case .auto:   auto += dur
            case .manual: manual += dur
            }
        }
        // Per-provider in-window counts; keep input order, drop zeros.
        let counts: [ProviderCount] = providerTimestamps.compactMap { entry in
            let c = entry.timestamps.reduce(into: 0) { acc, t in
                if t >= windowStart && t <= now { acc += 1 }
            }
            return c > 0 ? ProviderCount(provider: entry.provider, count: c) : nil
        }
        return WindowStats(awakeAuto: auto, awakeManual: manual, providerCounts: counts)
    }

    private static func formatCount(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    /// The "… events" footer/accessibility segment. Sole Claude → "3,005 events"
    /// (no name, matching the legacy footer). Otherwise each active provider is
    /// named: "Claude 3,005 · Codex 142 events". Always the plural noun so the
    /// label stays uniform across providers and counts.
    static func eventsSegment(_ counts: [ProviderCount]) -> String? {
        guard !counts.isEmpty else { return nil }
        if counts.count == 1, counts[0].provider == .claude {
            return "\(formatCount(counts[0].count)) events"
        }
        let body = counts
            .map { "\(providerDisplayName($0.provider)) \(formatCount($0.count))" }
            .joined(separator: " · ")
        return "\(body) events"
    }

    static func footerText(
        stats: WindowStats,
        window: TimeInterval = 8 * 3600
    ) -> String {
        let windowH = Int(window / 3600)
        guard stats.totalAwake > 0 || !stats.providerCounts.isEmpty else {
            return "No activity in the last \(windowH)h"
        }
        // No "Past Nh" prefix: the chart's x-axis already labels the span. The
        // window still appears in the accessibility label/value for VoiceOver.
        var parts: [String] = []
        if stats.totalAwake > 0 {
            parts.append("Awake for \(formatDuration(stats.totalAwake))")
        }
        if let events = eventsSegment(stats.providerCounts) {
            parts.append(events)
        }
        return parts.joined(separator: " · ")
    }

    /// Single-string accessibility value for the chart. Mirrors the visible
    /// footer chip in plain prose so VoiceOver reads the same facts the
    /// sighted user would glean from the wave + tint.
    static func chartAccessibilityValue(
        stats: WindowStats,
        window: TimeInterval = 8 * 3600
    ) -> String {
        if stats.totalAwake == 0 && stats.providerCounts.isEmpty {
            return "No activity in the last \(Int(window / 3600))h"
        }
        var sentenceParts: [String] = []
        if let events = eventsSegment(stats.providerCounts) {
            sentenceParts.append(events)
        }
        sentenceParts.append("Mac awake for \(formatDuration(stats.totalAwake))")
        if stats.awakeAuto > 0 && stats.awakeManual > 0 {
            sentenceParts.append("\(formatDuration(stats.awakeAuto)) auto, \(formatDuration(stats.awakeManual)) manual")
        } else if stats.awakeManual > 0 {
            sentenceParts.append("manual mode")
        }
        let body = sentenceParts.joined(separator: ", ")
        if window > 8 * 3600 {
            return "Past \(Int(window / 3600))h. \(body)"
        }
        return body
    }

    /// "1h 30m" / "45m" / "2h". Drops the minutes component when the
    /// duration is an exact multiple of an hour so the chip stays compact.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }
}
