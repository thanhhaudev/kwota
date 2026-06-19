//
//  UsageTrendChart.swift
//  Kwota
//
//  Predictive usage chart for two windows — current 5h session and calendar
//  week. Combines hourly/daily snapshot bars with recency emphasis, a ghost
//  projection bar (session only) extrapolating the next hour from the last 2-3
//  deltas, an historical-average reference line, and a pace-comparison hint.
//  The intent is to communicate "where you're heading", not just "where you've
//  been".

import SwiftUI
import Charts

/// Provider-agnostic chart input. Both Claude (UsageSnapshot) and Codex
/// (CodexUsageSnapshot) wrap themselves into this shape before handing off
/// to `UsageTrendChart`. The buckets passed in MUST already be clamped to
/// 0 once their resetsAt is in the past — providers apply that rule in
/// their respective `effective…()` accessors so this layer stays dumb.
struct UsageTrendChartInput {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    /// Whether the provider has received at least one successful fetch.
    /// Drives the "Waiting for first fetch…" placeholder in chart footnotes.
    let hasRealData: Bool
}

struct UsageTrendChart {
    let input: UsageTrendChartInput
    let history: [UsageHistoryEntry]
    let showAvg: Bool
    let showPaceHint: Bool

    /// Claude convenience initializer — wraps the snapshot's already-clamped
    /// buckets into the provider-agnostic input. Existing call sites compile
    /// unchanged.
    init(snapshot: UsageSnapshot,
         history: [UsageHistoryEntry],
         showAvg: Bool,
         showPaceHint: Bool) {
        self.input = UsageTrendChartInput(
            fiveHour: snapshot.effectiveFiveHour(),
            sevenDay: snapshot.effectiveSevenDay(),
            hasRealData: snapshot.fetchedAt != .distantPast
        )
        self.history = history
        self.showAvg = showAvg
        self.showPaceHint = showPaceHint
    }

    /// Direct initializer for callers that don't have a UsageSnapshot —
    /// new providers (e.g. Codex) build the input themselves from their
    /// own snapshot type.
    init(input: UsageTrendChartInput,
         history: [UsageHistoryEntry],
         showAvg: Bool,
         showPaceHint: Bool) {
        self.input = input
        self.history = history
        self.showAvg = showAvg
        self.showPaceHint = showPaceHint
    }

    enum Period { case session, weekly }
    enum XLabelStyle { case hourSuffixed, weekdayNarrow }

    /// Returns one card (chart + footnote) for the requested period. The caller
    /// is responsible for placing a `SectionHeader` above it.
    @ViewBuilder
    func card(for period: Period) -> some View {
        switch period {
        case .session:
            let avg = sessionAverageForChart
            section(
                bucket: input.fiveHour ?? UsageBucket(utilization: nil, resetsAt: nil),
                entries: sessionEntries,
                xStride: .hour,
                xLabelStyle: .hourSuffixed,
                avgReference: showAvg ? avg : nil,
                historicalAverage: avg,
                periodLabel: "session",
                trailingDetails: { EmptyView() }
            )
        case .weekly:
            weeklyCard()
        }
    }

    @ViewBuilder
    func weeklyCard<Trailing: View>(
        @ViewBuilder trailingDetails: @escaping () -> Trailing = { EmptyView() }
    ) -> some View {
        let weekly = weeklyEntries
        let avg = weekAverageForChart
        section(
            bucket: input.sevenDay ?? UsageBucket(utilization: nil, resetsAt: nil),
            entries: weekly,
            xStride: .day,
            xLabelStyle: .weekdayNarrow,
            avgReference: showAvg ? avg : nil,
            historicalAverage: avg,
            periodLabel: "week",
            trailingDetails: trailingDetails
        )
    }

    /// Avg line for the session chart, framed as **typical % at this elapsed
    /// time in past sessions** — a same-axis comparison that supports the
    /// "on pace" footnote. Heavy users hit ~100% near end-of-session, so
    /// using mean-of-peaks would render the line at the chart's cap and
    /// answer the wrong question (end-state vs mid-state).
    ///
    /// Implementation: segment `history` into completed cycles, then for each
    /// cycle take the LOCF sample at the current session's elapsed time,
    /// then mean. Returns `nil` when no completed cycle has a sample at-or-
    /// before currentElapsed (new profile, sparse polling, etc.) — the
    /// RuleMark's `if let avgReference` guard hides the line.
    private var sessionAverageForChart: Double? {
        let samples: [(at: Date, value: Double)] = history
            .compactMap { e in e.fiveHour.map { (e.at, $0) } }
            .sorted { $0.at < $1.at }
        let timelines = SessionAvgCalculator.sessionTimelines(from: samples)
        let elapsed = Date().timeIntervalSince(Self.currentSessionStart(fiveHourResetsAt: input.fiveHour?.resetsAt))
        return SessionAvgCalculator.avgAtElapsed(elapsed, in: timelines)
    }

    /// Avg line for the weekly chart, framed as **typical % at this elapsed
    /// point in past weeks**. Anchored to the same `cycleStart` that
    /// `weeklyEntries` uses — otherwise the LOCF lookup compares an
    /// elapsed-from-Monday `target` against past-cycle samples whose
    /// elapsed is measured from their own reset, and LOCF returns each
    /// cycle's peak (≈ 100%), producing the "avg always at top" bug.
    /// Returns `nil` when the resolver fell back to calendar Monday
    /// (`useAvgLine == false`), because no honest comparison is possible
    /// there.
    static func weeklyAverage(
        history: [UsageHistoryEntry],
        cycleStart: Date,
        useAvgLine: Bool,
        now: Date = Date()
    ) -> Double? {
        guard useAvgLine else { return nil }
        let samples: [(at: Date, value: Double)] = history
            .compactMap { e in e.sevenDay.map { (e.at, $0) } }
            .sorted { $0.at < $1.at }
        let timelines = WeekAvgCalculator.weeklyTimelines(from: samples)
        let elapsed = now.timeIntervalSince(cycleStart)
        return WeekAvgCalculator.avgAtElapsed(elapsed, in: timelines)
    }

    private var weekAverageForChart: Double? {
        let anchor = cycleAnchor
        return Self.weeklyAverage(
            history: history,
            cycleStart: anchor.cycleStart,
            useAvgLine: anchor.useAvgLine
        )
    }

    /// Resolved cycle anchor shared by `weekAverageForChart` and the weekly
    /// branch of `footnote(for:isSession:)`. Both consume `cycleStart`,
    /// `isHeuristic`, and `useAvgLine`; computing once per render keeps
    /// those three flags coherent within a single chart update. The static
    /// `weeklyEntries` resolves independently because its callers treat it
    /// as a standalone function.
    private var cycleAnchor: CycleAnchor {
        Self.resolveCycleStart(sevenDayResetsAt: input.sevenDay?.resetsAt, history: history)
    }

    /// Monday 00:00 of the current calendar week (firstWeekday = Monday).
    /// Mirrors the day-bucket logic in `weeklyEntries` so elapsed time is
    /// computed against the same anchor the chart's bars are.
    static func currentWeekStart(now: Date = Date()) -> Date {
        // Calendar.current intentional: "this week" should match the user's
        // local clock, not the UTC anchor used by the persistence layer.
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        return cal.date(byAdding: .day, value: -daysFromMonday, to: today) ?? today
    }

    /// Result of resolving the rolling-cycle anchor for the weekly chart.
    /// `useAvgLine == false` means we fell back to calendar Monday and the
    /// historical-average lookup would be unreliable (anchor mismatch with
    /// `WeekAvgCalculator` cycles), so the dashed line should be hidden.
    struct CycleAnchor: Equatable {
        let cycleStart: Date
        let isHeuristic: Bool
        let useAvgLine: Bool
    }

    /// Resolve the start of the current rolling 7-day cycle. Order of
    /// preference:
    ///   1. Stale API short-circuit (`resetsAt <= now`): `cycleStart = now`.
    ///      The server is behind a known reset; `effectiveSevenDay()` already
    ///      clamps utilization to 0%, so D1 renders empty and D2..D7 are
    ///      future ghosts.
    ///   2. API anchor (normal): `cycleStart = resetsAt - 7d` when
    ///      `resetsAt ∈ (now, now + 7d]`. Upper bound rejects pathological
    ///      values.
    ///   3. History heuristic: latest detected reset from
    ///      `WeekAvgCalculator.weeklyTimelines` — the first sample of the
    ///      trailing in-progress cycle. Sets `isHeuristic = true`.
    ///   4. Monday fallback: preserves today's behavior; hides avg line
    ///      because the Monday anchor doesn't match how past cycles are
    ///      segmented (the original bug).
    static func resolveCycleStart(
        snapshot: UsageSnapshot,
        history: [UsageHistoryEntry],
        now: Date = Date()
    ) -> CycleAnchor {
        resolveCycleStart(sevenDayResetsAt: snapshot.sevenDay.resetsAt, history: history, now: now)
    }

    /// Provider-agnostic overload used by instance computed properties
    /// that no longer hold a `UsageSnapshot`. Public-static call sites
    /// and tests continue to use the `snapshot:`-labelled overload above.
    private static func resolveCycleStart(
        sevenDayResetsAt resetsAt: Date?,
        history: [UsageHistoryEntry],
        now: Date = Date()
    ) -> CycleAnchor {
        let sevenDays: TimeInterval = 7 * 86_400

        if let resetsAt, resetsAt <= now {
            return CycleAnchor(cycleStart: now, isHeuristic: false, useAvgLine: true)
        }
        // High-confidence override: Anthropic occasionally recalibrates
        // `seven_day.utilization` mid-cycle (e.g. cap raised, model
        // recategorized) without updating `resets_at`. The API anchor
        // then claims a cycle that started 7 days before resets_at, but
        // Kwota's own history shows utilization clearly fell off a cliff
        // somewhere in between. When that drop is unambiguous AND lands
        // meaningfully later than the API anchor, anchor the chart on
        // the drop — matching what the user actually sees in the bars.
        // Strict threshold (prev > 40%, current < 10%) keeps false
        // positives low; smaller wobbles still fall through to the API
        // anchor.
        //
        // The 24h grace window absorbs polling lag: if Kwota was idle
        // (Mac asleep, app closed) when the cycle's normal reset fired,
        // the next post-wake sample lands hours after `resets_at - 7d`
        // but describes the same event — without the grace, the override
        // fires on every normal reset and the footer reads "calibrating"
        // until the drop sample ages out. Real mid-cycle recalibrations
        // land days into the cycle, well past the grace window.
        let strictDropGrace: TimeInterval = 24 * 3600
        if let resetsAt,
           let strictDrop = Self.latestStrictResetStart(in: history),
           strictDrop > resetsAt.addingTimeInterval(-sevenDays + strictDropGrace) {
            return CycleAnchor(cycleStart: strictDrop, isHeuristic: true, useAvgLine: true)
        }
        if let resetsAt, resetsAt <= now.addingTimeInterval(sevenDays) {
            return CycleAnchor(
                cycleStart: resetsAt.addingTimeInterval(-sevenDays),
                isHeuristic: false,
                useAvgLine: true
            )
        }
        // Heuristic: find the trailing in-progress cycle's start by re-running
        // the reset-drop scanner over history. We mirror weeklyTimelines'
        // scan because that function intentionally drops the trailing cycle.
        if let heuristicStart = Self.latestDetectedCycleStart(in: history) {
            return CycleAnchor(cycleStart: heuristicStart, isHeuristic: true, useAvgLine: true)
        }
        return CycleAnchor(
            cycleStart: Self.currentWeekStart(now: now),
            isHeuristic: false,
            useAvgLine: false
        )
    }

    /// Walk sevenDay samples in chronological order; return the timestamp of
    /// the first sample after the most recent reset-drop (≥ 5% drop, matching
    /// `WeekAvgCalculator`'s threshold). Returns `nil` when there's no usable
    /// signal — either history is empty or there's no completed prior cycle
    /// to mark a reset boundary.
    private static func latestDetectedCycleStart(in history: [UsageHistoryEntry]) -> Date? {
        let samples = history
            .compactMap { e -> (at: Date, value: Double)? in
                e.sevenDay.map { (e.at, $0) }
            }
            .sorted { $0.at < $1.at }
        guard !samples.isEmpty else { return nil }
        var cycleStart: Date? = nil
        var prev: Double? = nil
        for (at, v) in samples {
            if let p = prev, v < p - 5.0 {
                cycleStart = at
            }
            prev = v
        }
        return cycleStart
    }

    /// Stricter variant of `latestDetectedCycleStart` used by the
    /// chart-anchor override path. Flags a sample as the cycle start
    /// only when the previous reading was high (> 40%) AND the current
    /// reading is unambiguously low (< 10%). Matches the user-approved
    /// "high-confidence" threshold for overriding a factual API anchor
    /// — anything looser risks anchoring on noise (transient API
    /// recalibration, plan-cap bumps that don't represent a real reset).
    static func latestStrictResetStart(in history: [UsageHistoryEntry]) -> Date? {
        let samples = history
            .compactMap { e -> (at: Date, value: Double)? in
                e.sevenDay.map { (e.at, $0) }
            }
            .sorted { $0.at < $1.at }
        guard !samples.isEmpty else { return nil }
        var cycleStart: Date? = nil
        var prev: Double? = nil
        for (at, v) in samples {
            if let p = prev, p > 40, v < 10 {
                cycleStart = at
            }
            prev = v
        }
        return cycleStart
    }

    /// Most recent mid-cycle server recalibration of the weekly limit: a
    /// chronological `sevenDay` drop large enough to be a deliberate cap change
    /// (≥ 15 points) yet NOT a reset (`current >= 10`, which the strict-reset path
    /// already owns). Returns the timestamp of the sample the drop landed on, or
    /// `nil`. Drives ONLY the explanatory "server recalibrated" footnote — it never
    /// moves the cycle anchor, bars, or avg-line.
    static func latestRecalibrationStart(in history: [UsageHistoryEntry]) -> Date? {
        let samples = history
            .compactMap { e -> (at: Date, value: Double)? in
                e.sevenDay.map { (e.at, $0) }
            }
            .sorted { $0.at < $1.at }
        guard !samples.isEmpty else { return nil }
        var recalibration: Date? = nil
        var prev: Double? = nil
        for (at, v) in samples {
            if let p = prev, p - v >= 15, v >= 10 {
                recalibration = at
            }
            prev = v
        }
        return recalibration
    }

    /// True when the latest detected recalibration falls inside the currently
    /// displayed cycle (`>= cycleStart`), so the hint clears at the next real
    /// reset / new cycle instead of lingering.
    static func isRecalibrationActive(history: [UsageHistoryEntry], cycleStart: Date) -> Bool {
        latestRecalibrationStart(in: history).map { $0 >= cycleStart } ?? false
    }

    @ViewBuilder
    private func section<Trailing: View>(
        bucket: UsageBucket,
        entries: [Entry],
        xStride: Calendar.Component,
        xLabelStyle: XLabelStyle,
        avgReference: Double?,
        historicalAverage: Double?,
        periodLabel: String,
        @ViewBuilder trailingDetails: @escaping () -> Trailing
    ) -> some View {
        let isSession = (xLabelStyle == .hourSuffixed)
        let displayEntries = isSession ? entries.appendingProjection() : entries
        let emphasis: BarEmphasis = isSession ? .recentTwo : .lastOnly
        VStack(alignment: .leading, spacing: 6) {
            chart(
                entries: entries,
                displayEntries: displayEntries,
                tint: UsageLevel.tint(for: bucket.utilization),
                xStride: xStride,
                xLabelStyle: xLabelStyle,
                emphasis: emphasis,
                avgReference: avgReference
            )
            .frame(height: 90)
            .padding(.top, 6)

            // Single Text joining all available footnote parts with "·" so
            // short content sits on one line. Wraps to up to 2 lines only
            // when the combined string genuinely doesn't fit.
            let parts: [String] = [
                footnote(for: bucket, isSession: isSession),
                showPaceHint ? Self.paceHint(latest: bucket.utilization, historicalAverage: historicalAverage) : nil,
                isSession ? Self.velocityFootnote(realEntries: entries, bucket: bucket) : nil
            ].compactMap { $0 }
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            _TrailingDetailsBlock { trailingDetails() }
        }
        .kwotaCard()
    }

    /// Compares current utilization against the historical avg (past sessions
    /// or weeks). Returns a short one-liner: "on pace · typical 47%",
    /// "above typical 47% · heavy", or "below typical 47%". All-lowercase to
    /// match the surrounding microcopy fragments ("52% used", "~40m left",
    /// "≈ 47m to limit") joined by " · " — sentence-case here read as a
    /// broken capitalization mid-string. Suppressed when `latest >= 100`,
    /// the user has already saturated and the comparison is noise alongside
    /// "0% remaining · ~Xh Ym left".
    static func paceHint(latest: Double?, historicalAverage avg: Double?) -> String? {
        guard let latest, let avg else { return nil }
        guard latest < 100 else { return nil }
        let avgInt = Int(avg.rounded())
        let diff = latest - avg
        if abs(diff) < 5 {
            return "on pace · typical \(avgInt)%"
        } else if diff > 0 {
            return "above typical \(avgInt)% · heavy"
        } else {
            return "below typical \(avgInt)%"
        }
    }

    enum BarEmphasis { case recentTwo, lastOnly }

    @ViewBuilder
    private func chart(
        entries: [Entry],
        displayEntries: [Entry],
        tint: Color,
        xStride: Calendar.Component,
        xLabelStyle: XLabelStyle,
        emphasis: BarEmphasis,
        avgReference: Double?
    ) -> some View {
        if displayEntries.isEmpty {
            skeletonBars(period: xLabelStyle == .hourSuffixed ? .session : .weekly)
        } else {
            // Render through a dedicated View so SwiftUI tracks the warm
            // pulse's time-based redraws via `TimelineView`. Keeping the
            // pulse driver scoped to its own view means the parent
            // `UsageTrendChart` doesn't have to become a View itself, and
            // weekly callers (no warm pulse) pay no animation cost — see
            // `_ChartBody.body` for the `paused: !warmLatest` gate.
            _ChartBody(
                entries: entries,
                displayEntries: displayEntries,
                tint: tint,
                xStride: xStride,
                xLabelStyle: xLabelStyle,
                emphasis: emphasis,
                avgReference: avgReference
            )
        }
    }

    /// Empty-state skeleton: a chart frame built from dashed lines —
    /// horizontal gridlines (top / mid / baseline) plus dashed-border bars
    /// scaled to the container's height. Communicates "chart shape" without
    /// faking values.
    @ViewBuilder
    private func skeletonBars(period: Period) -> some View {
        let count = period == .session ? 5 : 7
        let fractions: [CGFloat] = period == .session
            ? [0.50, 0.70, 0.55, 0.85, 0.65]
            : [0.40, 0.60, 0.50, 0.80, 0.55, 0.70, 0.45]
        let stroke = StrokeStyle(lineWidth: 0.8, dash: [3, 2])
        let color = Color.secondary.opacity(0.35)

        GeometryReader { geo in
            ZStack {
                // 3 horizontal dashed gridlines: 100%, 50%, baseline.
                VStack(spacing: 0) {
                    skeletonGridline(color: color, stroke: stroke)
                    Spacer()
                    skeletonGridline(color: color, stroke: stroke)
                    Spacer()
                    skeletonGridline(color: color, stroke: stroke)
                }

                // Dashed bars scaled to fractions of available height.
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(0..<count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(color, style: stroke)
                            .frame(maxWidth: .infinity)
                            .frame(height: max(8, geo.size.height * (fractions[safe: i] ?? 0.6)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 4)
            }
        }
    }

    private func skeletonGridline(color: Color, stroke: StrokeStyle) -> some View {
        SkeletonRule()
            .stroke(color, style: stroke)
            .frame(height: 0.5)
    }

    // MARK: - Derived

    private var weeklyEntries: [Entry] {
        Self.weeklyEntries(
            sevenDayResetsAt: input.sevenDay?.resetsAt,
            effectiveSevenDayUtilization: input.sevenDay?.utilization,
            history: history
        )
    }

    /// 7-bar series anchored to the user's rolling 7-day cycle (not the
    /// calendar Mon-Sun week). `cycleStart` is resolved from
    /// `resolveCycleStart(snapshot:history:now:)`. Each bar represents the
    /// end-of-day cumulative `sevenDay` utilization for that cycle-day.
    /// Past days carry forward (LOCF) when no fresh sample exists. Future
    /// days emit `value = 0, isFuture = true` (ghost placeholder — not a
    /// projection). Samples timestamped before `cycleStart` are filtered
    /// out so prior-cycle data cannot pollute current-cycle bars.
    static func weeklyEntries(
        snapshot: UsageSnapshot,
        history: [UsageHistoryEntry],
        now: Date = Date()
    ) -> [Entry] {
        weeklyEntries(
            sevenDayResetsAt: snapshot.sevenDay.resetsAt,
            effectiveSevenDayUtilization: snapshot.effectiveSevenDay(now: now).utilization,
            history: history,
            now: now
        )
    }

    /// Provider-agnostic overload used by instance computed properties.
    private static func weeklyEntries(
        sevenDayResetsAt: Date?,
        effectiveSevenDayUtilization: Double?,
        history: [UsageHistoryEntry],
        now: Date = Date()
    ) -> [Entry] {
        let anchor = resolveCycleStart(sevenDayResetsAt: sevenDayResetsAt, history: history, now: now)
        let cal = Calendar.current
        let cycleStartDay = cal.startOfDay(for: anchor.cycleStart)
        let todayStart = cal.startOfDay(for: now)

        // Bucketing snaps to midnight (`cycleStartDay`) so the 7 day-bars
        // align visually with the user's local clock. The pre-cycle filter
        // uses the precise `anchor.cycleStart` (which can be sub-day, e.g.
        // a 03:00 reset), so prior-cycle samples timestamped between
        // midnight and `cycleStart` are still excluded — the bucketing
        // window is wider than the filter on D1, but only by minutes that
        // belong to the prior cycle by definition. Do not "simplify" by
        // dropping the filter: a future tweak that loosens the bucket
        // boundaries could otherwise let pre-cycle samples leak into D1.
        let inCycle = history.filter { $0.at >= anchor.cycleStart }

        var entries: [Entry] = []
        var lastSeen: Double = 0
        for offset in 0..<7 {
            guard let dayStart = cal.date(byAdding: .day, value: offset, to: cycleStartDay) else { continue }
            if dayStart > todayStart {
                entries.append(Entry(at: dayStart, value: 0, isFuture: true))
                continue
            }
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            let samples = inCycle.filter { $0.at >= dayStart && $0.at < dayEnd }
            let latest = samples
                .compactMap { e -> (Date, Double)? in
                    guard let v = e.sevenDay else { return nil }
                    return (e.at, v)
                }
                .max(by: { $0.0 < $1.0 })
            let v = latest.map { Swift.min($0.1, 100) } ?? lastSeen
            lastSeen = v
            entries.append(Entry(at: dayStart, value: v))
        }
        return Self.applyTrailingResetClamp(
            entries: entries,
            effectiveUtilization: effectiveSevenDayUtilization
        )
    }

    /// First-hour-boundary of the current 5h session window. Prefers
    /// `snapshot.fiveHour.resetsAt - 5h` (the API tells us exactly when the
    /// window resets); falls back to `nowHour - 5h`. Clamped into
    /// `[nowHour - 5h, nowHour]` so anomalous API responses can't push the
    /// session start outside the chart's visible range.
    static func currentSessionStart(snapshot: UsageSnapshot, now: Date = Date()) -> Date {
        currentSessionStart(fiveHourResetsAt: snapshot.fiveHour.resetsAt, now: now)
    }

    /// Provider-agnostic overload used by instance computed properties.
    private static func currentSessionStart(fiveHourResetsAt resetsAt: Date?, now: Date = Date()) -> Date {
        // Calendar.current intentional: render-time hour-bucket alignment for
        // the session chart's x-axis, follows user clock.
        let cal = Calendar.current
        guard let nowHour = cal.dateInterval(of: .hour, for: now)?.start else { return now }
        let lowerBound = nowHour.addingTimeInterval(-5 * 3600)
        let rawStart: Date = {
            if let resetsAt,
               let s = cal.dateInterval(of: .hour, for: snapToMinute(resetsAt).addingTimeInterval(-5 * 3600))?.start {
                return s
            }
            return lowerBound
        }()
        return max(lowerBound, min(rawStart, nowHour))
    }

    /// Rounds a timestamp to the nearest minute. The claude.ai usage API
    /// returns `five_hour.resets_at` with ~1s jitter that straddles exact
    /// hour boundaries (observed: 12:00:00 ↔ 11:59:59 across consecutive
    /// fetches). Because `currentSessionStart` floors `resetsAt − 5h` to the
    /// hour, that 1s wobble flips the session start by a full hour
    /// (07:00 ↔ 06:00) and reshapes the chart on every refresh. Snapping to
    /// the nearest minute first absorbs sub-30s jitter; a 1-minute rounding on
    /// a 5-hour window is immaterial for hour-bucket alignment.
    static func snapToMinute(_ date: Date) -> Date {
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 60).rounded() * 60)
    }

    private var sessionEntries: [Entry] {
        Self.sessionEntries(
            fiveHourResetsAt: input.fiveHour?.resetsAt,
            effectiveFiveHourUtilization: input.fiveHour?.utilization,
            history: history
        )
    }

    /// Hourly buckets spanning the current session, plus backfill from the
    /// previous session when the current one has fewer than 5 hours so far.
    /// Hours without samples carry forward the previous hour's value (LOCF),
    /// so flat segments mean "user was idle / no poll" rather than
    /// "quota dropped to 0%".
    ///
    /// Backfill is suppressed when the previous-session window has no
    /// samples in `history` — first-time users see only their current
    /// session's bars (1–5), no separator.
    static func sessionEntries(
        snapshot: UsageSnapshot,
        history: [UsageHistoryEntry],
        now: Date = Date()
    ) -> [Entry] {
        sessionEntries(
            fiveHourResetsAt: snapshot.fiveHour.resetsAt,
            effectiveFiveHourUtilization: snapshot.effectiveFiveHour(now: now).utilization,
            history: history,
            now: now
        )
    }

    /// Provider-agnostic overload used by instance computed properties.
    private static func sessionEntries(
        fiveHourResetsAt: Date?,
        effectiveFiveHourUtilization: Double?,
        history: [UsageHistoryEntry],
        now: Date = Date()
    ) -> [Entry] {
        // Calendar.current intentional: render-time, user-locale hour buckets.
        let cal = Calendar.current
        guard let nowHour = cal.dateInterval(of: .hour, for: now)?.start else { return [] }

        let currentStart = Self.currentSessionStart(fiveHourResetsAt: fiveHourResetsAt, now: now)

        // Cap at 5 — when `now.minute < resetsAt.minute`,
        // `currentSessionStart` lands on `nowHour - 5h` (resetsAt-5h rounds
        // DOWN), so `hourlyBars` would emit 6 inclusive hour buckets. The
        // chart's X-domain is locked to a 5-slot frame, so the 6th bleeds
        // past the left edge. Mirror of the cap in `appendingProjection()`.
        let currentBars = Array(Self.hourlyBars(
            history: history,
            from: currentStart,
            through: nowHour,
            seedingFrom: 0,
            isPrev: false
        ).suffix(5))

        guard currentBars.count < 5 else {
            return Self.applyTrailingResetClamp(
                entries: currentBars,
                effectiveUtilization: effectiveFiveHourUtilization
            )
        }

        // Previous session = the 5-hour window that ended at the most recent
        // reset (= currentStart). Skip backfill when there is no recorded
        // sample inside that window — there's nothing meaningful to show.
        let prevStart = currentStart.addingTimeInterval(-5 * 3600)
        let prevEnd = currentStart.addingTimeInterval(-3600)
        let prevHasData = history.contains { entry in
            entry.at >= prevStart && entry.at < currentStart && entry.fiveHour != nil
        }
        guard prevHasData else {
            return Self.applyTrailingResetClamp(
                entries: currentBars,
                effectiveUtilization: effectiveFiveHourUtilization
            )
        }

        let prevBars = Self.hourlyBars(
            history: history,
            from: prevStart,
            through: prevEnd,
            seedingFrom: 0,
            isPrev: true
        )
        let needed = 5 - currentBars.count
        let backfill = Array(prevBars.suffix(needed))
        return Self.applyTrailingResetClamp(
            entries: backfill + currentBars,
            effectiveUtilization: effectiveFiveHourUtilization
        )
    }

    /// Builds inclusive-range hourly bars `[start, start+1h, …, end]`,
    /// LOCF-filling each hour from `history.fiveHour` samples.
    static func hourlyBars(
        history: [UsageHistoryEntry],
        from start: Date,
        through end: Date,
        seedingFrom: Double,
        isPrev: Bool
    ) -> [Entry] {
        guard start <= end else { return [] }
        var hours: [Date] = []
        var t = start
        while t <= end {
            hours.append(t)
            t = t.addingTimeInterval(3600)
        }

        var entries: [Entry] = []
        var lastSeen = seedingFrom
        for hour in hours {
            let next = hour.addingTimeInterval(3600)
            let samples = history.filter { $0.at >= hour && $0.at < next }
            let last = samples
                .compactMap { e -> (Date, Double)? in
                    guard let v = e.fiveHour else { return nil }
                    return (e.at, v)
                }
                .max(by: { $0.0 < $1.0 })
            let v = last.map { Swift.min($0.1, 100) } ?? lastSeen
            lastSeen = v
            entries.append(Entry(at: hour, value: v, isPreviousSession: isPrev))
        }
        return entries
    }

    @ViewBuilder
    static func xLabel(for date: Date, style: XLabelStyle, todayDay: Date) -> some View {
        switch style {
        case .hourSuffixed:
            // Calendar.current intentional: render-time, user-locale.
            let cal = Calendar.current
            let nowHour = cal.dateInterval(of: .hour, for: Date())?.start ?? Date()
            let dh = cal.dateComponents([.hour], from: nowHour, to: date).hour ?? 0
            let label: String = {
                if dh == 0 { return "now" }
                if dh > 0 { return "+\(dh)h" }
                return "\(dh)h"
            }()
            Text(label).font(.caption2)
        case .weekdayNarrow:
            // Calendar.current intentional: render-time "today" highlight.
            let isToday = Calendar.current.isDate(date, inSameDayAs: todayDay)
            Text(date, format: .dateTime.weekday(.narrow))
                .font(.caption2)
                .fontWeight(isToday ? .semibold : .regular)
                .foregroundStyle(isToday ? .primary : .secondary)
        }
    }

    private var hasRealData: Bool { input.hasRealData }

    /// "~4h 17m left" / "~17m left" / "~3d 4h left". Drops minutes when ≥24h.
    static func formatHoursMinutesLeft(until target: Date) -> String {
        let total = Swift.max(0, Int(target.timeIntervalSince(Date())))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 {
            return "~\(days)d \(hours)h left"
        }
        if hours > 0 {
            return "~\(hours)h \(minutes)m left"
        }
        return "~\(minutes)m left"
    }

    /// Weekly footnote composition extracted as a pure static helper so we
    /// can test the hybrid countdown + calibrating suffix without spinning
    /// up a SwiftUI view. The session footnote path remains in
    /// `footnote(for:isSession:)`.
    static func weeklyFootnoteText(
        bucket: UsageBucket,
        hasRealData: Bool,
        isHeuristic: Bool,
        isRecalibrated: Bool = false,
        now: Date = Date()
    ) -> String {
        guard hasRealData else { return "Waiting for first fetch…" }
        let usage: String? = bucket.utilization.map { u in
            if u < UsageLevel.warningThreshold {
                return "\(Int(u))% used"
            } else {
                let remaining = max(0, 100 - Int(u))
                return "\(remaining)% remaining"
            }
        }
        let resets: String? = bucket.resetsAt.map { formatResetCountdown(until: $0, now: now) }
        var parts = [usage, resets].compactMap { $0 }
        if isHeuristic {
            parts.append("calibrating")
        }
        if isRecalibrated {
            parts.append("server recalibrated")
        }
        return parts.joined(separator: " · ")
    }

    private func footnote(for bucket: UsageBucket, isSession: Bool) -> String? {
        if !isSession {
            let anchor = cycleAnchor
            let isRecalibrated = Self.isRecalibrationActive(
                history: history, cycleStart: anchor.cycleStart)
            let text = Self.weeklyFootnoteText(
                bucket: bucket,
                hasRealData: hasRealData,
                isHeuristic: anchor.isHeuristic,
                isRecalibrated: isRecalibrated
            )
            return text.isEmpty ? nil : text
        }
        // Session path is unchanged.
        guard hasRealData else { return "Waiting for first fetch…" }
        let usage: String? = bucket.utilization.map { u in
            if u < UsageLevel.warningThreshold {
                return "\(Int(u))% used"
            } else {
                let remaining = max(0, 100 - Int(u))
                return "\(remaining)% remaining"
            }
        }
        let resets: String? = bucket.resetsAt.map { Self.formatHoursMinutesLeft(until: $0) }
        let parts = [usage, resets].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    struct Entry: Identifiable {
        let at: Date
        let value: Double
        var isProjection: Bool = false
        var isFuture: Bool = false
        /// Bar belongs to the session that was active before the most recent
        /// reset — backfilled when the current session has < 5 hourly bars.
        /// Rendered in neutral gray to distinguish from current-session bars.
        var isPreviousSession: Bool = false

        /// Stable identity for Charts' ForEach. Combines bucket timestamp
        /// with the role flags so the same bar (e.g. "-1h" in the session
        /// chart) keeps its identity across renders — Charts can then
        /// animate value transitions in-place instead of pop-replacing.
        ///
        /// The flag combination matters because the same `at` timestamp can
        /// belong to either a real bar or a projection bar (e.g. at session
        /// end, the projection sits at `now + 1h` and would otherwise be
        /// confused with a real bar that crosses that boundary on the next
        /// tick).
        ///
        /// Nested Hashable struct (auto-synthesized) so SwiftUI's diffing
        /// dictionary hashes the actual stored values rather than a
        /// stringified form — sturdier than string interpolation when the
        /// `at` values are very close together.
        struct ID: Hashable {
            let at: Date
            let isProjection: Bool
            let isPreviousSession: Bool
            let isFuture: Bool
        }

        var id: ID {
            ID(at: at,
               isProjection: isProjection,
               isPreviousSession: isPreviousSession,
               isFuture: isFuture)
        }
    }

    // MARK: - Accessibility

    /// Human-readable label for a single bar, used by VoiceOver. Returned
    /// strings are short and free of internal jargon — "Previous session,
    /// 2 hours ago" rather than "isPreviousSession bar at -2h".
    static func barAccessibilityLabel(entry: Entry, style: XLabelStyle) -> String {
        if entry.isProjection { return "Projected next hour" }
        if entry.isFuture     { return "Future day" }
        switch style {
        case .hourSuffixed:
            // Calendar.current intentional: same anchor as the visible label.
            let cal = Calendar.current
            let nowHour = cal.dateInterval(of: .hour, for: Date())?.start ?? Date()
            let dh = cal.dateComponents([.hour], from: nowHour, to: entry.at).hour ?? 0
            if dh == 0 {
                return entry.isPreviousSession ? "Previous session, current hour" : "Current hour"
            }
            if dh < 0 {
                let h = -dh
                let prefix = entry.isPreviousSession ? "Previous session, " : ""
                return "\(prefix)\(h) hour\(h == 1 ? "" : "s") ago"
            }
            return "In \(dh) hour\(dh == 1 ? "" : "s")"
        case .weekdayNarrow:
            return entry.at.formatted(.dateTime.weekday(.wide))
        }
    }

    /// Accessibility value paired with `barAccessibilityLabel`. Reads the
    /// percentage as an integer; future-day placeholders read as
    /// "no data yet" to match their visual ghost treatment.
    static func barAccessibilityValue(entry: Entry) -> String {
        if entry.isFuture { return "no data yet" }
        return "\(Int(entry.value.rounded())) percent"
    }

    // MARK: - Bar styling

    /// Color for the session chart's projection ghost bar.
    ///
    /// Threshold tint of the *projected* value (not the current one) — so a
    /// projection crossing 60% reads yellow even when the current bar is
    /// still green. The "above typical · heavy" warm pace signal lives on
    /// the focal `now` bar as a pulsing opacity (see `_ChartBody`) and does
    /// NOT propagate to the projection: warm is a now-signal, not a
    /// forecast.
    static func projectionColor(projectedValue: Double) -> Color {
        UsageLevel.tint(for: projectedValue)
    }

    /// Threshold tint for a real (non-projection, non-future, non-prev-session)
    /// bar — derived from THIS bar's own cumulative value, not from the
    /// bucket's current utilization. Mirrors `projectionColor`'s rule so the
    /// chart reads as a per-hour story: a -3h bar at 30% stays green even
    /// after the now-bar crosses into red at 80%. Without this, all real
    /// bars share a single bucket-derived tint and the previous hours flip
    /// color whenever the current cumulative crosses a threshold.
    static func realBarTint(value: Double) -> Color {
        UsageLevel.tint(for: value)
    }

    /// Bar color/opacity for a single chart bar.
    ///
    /// `warmLatest` and `pulseValue` together control the "above typical ·
    /// heavy" warm pulse on the focal bar (session chart only). When
    /// `warmLatest` is true, the focal bar's opacity is dimmed by up to 35%
    /// at the peak of the pulse (`pulseValue == 1`) and returns to full
    /// (`pulseValue == 0`) — a "breathing" effect that signals heavy pace
    /// without contradicting the threshold heat ladder. Hue stays purely
    /// threshold-derived (green/yellow/red), so 45% never reads "hotter"
    /// than 70% the way an orange-vs-yellow override did.
    ///
    /// Static so `_ChartBody` (the wrapper View that owns the pulse timing
    /// state) can call it without holding a `UsageTrendChart` instance.
    static func barColor(
        for entry: Entry,
        indexInDisplay idx: Int,
        displayCount: Int,
        hasProjection: Bool,
        tint: Color,
        warmLatest: Bool,
        emphasis: BarEmphasis,
        todayIdx: Int?,
        pulseValue: Double
    ) -> AnyShapeStyle {
        if entry.isPreviousSession {
            return AnyShapeStyle(Color.secondary.opacity(0.45).gradient)
        }
        if entry.isProjection {
            let color = projectionColor(projectedValue: entry.value)
            return AnyShapeStyle(color.opacity(0.15).gradient)
        }
        if entry.isFuture {
            return AnyShapeStyle(tint.opacity(0.2).gradient)
        }
        // Projection (when present) occupies the rightmost slot, so the last
        // *real* bar is at displayCount-2. When no projection was appended
        // (e.g. only 1 current-session bar exists, so pace can't be computed),
        // the last real bar is the rightmost slot itself — without this guard
        // the "now" bar would be treated as older and rendered at 0.4 opacity.
        let projectionOffset = (emphasis == .recentTwo && hasProjection) ? 1 : 0
        let lastRealIdx = displayCount - 1 - projectionOffset
        // For weekly, "today" is supplied by the caller; for session, it's the
        // last real bar.
        let focalIdx = todayIdx ?? lastRealIdx
        let isLatest = (idx == focalIdx)

        var opacity: Double
        switch emphasis {
        case .recentTwo:
            // Three-tier: now=1.0, -1h=0.7, older=0.4.
            if idx == focalIdx {
                opacity = 1.0
            } else if idx == focalIdx - 1 {
                opacity = 0.7
            } else {
                opacity = 0.4
            }
        case .lastOnly:
            // Today full; past 0.5.
            opacity = isLatest ? 1.0 : 0.5
        }

        // Warm pulse: only the session chart's focal `now` bar, only when
        // the latest value is more than 5% above the historical avg at this
        // elapsed time. `pulseValue` is driven by a TimelineView in
        // `_ChartBody`; it oscillates 0..1 over the pulse period when
        // active and stays at 0 otherwise. Dim by 20% at peak — wide enough
        // to read as a breath, narrow enough that green doesn't drift into
        // olive when blended against the dark card.
        let isWarmFocal = warmLatest && isLatest && emphasis == .recentTwo
        if isWarmFocal {
            let clamped = Swift.min(1.0, Swift.max(0.0, pulseValue))
            opacity *= 1.0 - 0.20 * clamped
        }
        // Per-bar threshold tint (see `realBarTint`). The `tint` parameter
        // is kept on the signature for `isFuture` ghosts (weekly chart) so
        // the placeholder fade still tracks the current bucket — those bars
        // have no own value to threshold against.
        let perBarTint = Self.realBarTint(value: entry.value)
        return AnyShapeStyle(perBarTint.opacity(opacity).gradient)
    }

    // MARK: - Velocity / projection footnote

    static func velocityFootnote(realEntries: [Entry], bucket: UsageBucket) -> String? {
        guard
            let latest = realEntries.last?.value,
            latest < 100,
            let pace = realEntries.averageDeltaPerHour(),
            pace > 0.5
        else { return nil }

        let remaining = max(0, 100 - latest)
        let hoursToLimit = remaining / pace
        let minutesToLimit = Int((hoursToLimit * 60).rounded())

        if let resetsAt = bucket.resetsAt {
            let minutesToReset = Int(resetsAt.timeIntervalSince(Date()) / 60)
            // Only flag if the user will hit the limit before reset.
            guard minutesToLimit < minutesToReset else { return nil }
        }
        return "≈ \(Self.formatShortDuration(minutes: minutesToLimit)) to limit"
    }

    /// Rewrites the value of the trailing real entry to 0 when the effective
    /// (reset-clamped) bucket reports 0 — keeps the chart's "now" bar in
    /// sync with the footer's "0% remaining" string in the brief window
    /// between an API-declared reset and the next successful fetch.
    ///
    /// "Trailing real entry" means the last entry whose `isFuture == false` —
    /// for session that's always the rightmost bar; for weekly that's today
    /// (regardless of weekday), since future-day placeholders sit at the end
    /// of the array.
    ///
    /// `effectiveUtilization == nil` means the API didn't surface a value
    /// (sparse polling, missing header). Don't overwrite in that case —
    /// LOCF is the right behavior when we don't know.
    static func applyTrailingResetClamp(
        entries: [Entry],
        effectiveUtilization: Double?
    ) -> [Entry] {
        guard let effective = effectiveUtilization,
              effective == 0,
              let lastIdx = entries.lastIndex(where: { !$0.isFuture }),
              entries[lastIdx].value > 0
        else { return entries }
        var rewritten = entries
        let last = rewritten[lastIdx]
        rewritten[lastIdx] = Entry(
            at: last.at,
            value: 0,
            isProjection: last.isProjection,
            isFuture: last.isFuture,
            isPreviousSession: last.isPreviousSession
        )
        return rewritten
    }

    /// Reset countdown string for the weekly footnote. Single absolute
    /// format ("resets Sat 6:00 AM") regardless of how far the reset is,
    /// mirroring claude.ai's own display so the two surfaces don't
    /// disagree on what "Sat" refers to. Past/zero delta clamps to
    /// "resets now" so stale data doesn't render a confusing future
    /// timestamp.
    ///
    /// Why not relative ("in 14h") for short windows: a relative string
    /// loses the day-of-week anchor that resolves ambiguity when the
    /// chart's history visually drops mid-cycle. Absolute time is
    /// always interpretable against the calendar without the user
    /// having to compute "14h from now" in their head.
    static func formatResetCountdown(until target: Date, now: Date = Date()) -> String {
        if target.timeIntervalSince(now) <= 0 {
            return "resets now"
        }
        let formatted = target.formatted(
            .dateTime
                .weekday(.abbreviated)
                .hour(.defaultDigits(amPM: .abbreviated))
                .minute()
        )
        return "resets \(formatted)"
    }

    /// "47m" for under an hour, "3h 46m" for an hour or more. Used by the
    /// velocity footnote so long durations don't push the line into 2 rows.
    static func formatShortDuration(minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let rem = m % 60
        return rem == 0 ? "\(h)h" : "\(h)h \(rem)m"
    }
}

/// Sub-view hosting the actual `Chart {}` for `UsageTrendChart`. Owns the
/// warm-pulse timeline: when the session chart's focal bar is flagged
/// `warmLatest`, `TimelineView(.animation)` re-renders the chart at ~30fps
/// so the focal bar's opacity oscillates via `barColor`'s `pulseValue`.
/// When not warm, the schedule is paused — weekly callers and quiet
/// sessions pay no animation cost.
private struct _ChartBody: View {
    let entries: [UsageTrendChart.Entry]
    let displayEntries: [UsageTrendChart.Entry]
    let tint: Color
    let xStride: Calendar.Component
    let xLabelStyle: UsageTrendChart.XLabelStyle
    let emphasis: UsageTrendChart.BarEmphasis
    let avgReference: Double?

    var body: some View {
        // Calendar.current intentional: render-time, user-locale.
        let cal = Calendar.current
        let todayDay = cal.startOfDay(for: Date())
        let todayIdx: Int? = displayEntries.firstIndex {
            !$0.isProjection && cal.isDate($0.at, inSameDayAs: todayDay)
        }
        let latestRealValue = entries.last(where: { !$0.isProjection && !$0.isFuture })?.value
        // 5% deadband matches paceHint's "above typical · heavy" branch —
        // pulse animation and footer text flip together instead of the bar
        // breathing while the text still says "on pace".
        let warmLatest = (latestRealValue ?? 0) > (avgReference ?? .infinity) + 5
        // Lock the session chart to a 5-slot frame whose right edge tracks
        // whether a projection ghost exists:
        //   • With projection → -3h, -2h, -1h, now, +1h.
        //   • Without projection → -4h, -3h, -2h, -1h, now.
        // End the domain 50min past the rightmost tick so .stride(by: .hour)
        // doesn't generate a 6th tick.
        let nowHour = cal.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let firstCurrent = displayEntries.first(where: { !$0.isPreviousSession && !$0.isProjection && !$0.isFuture })
        let hasProjection = displayEntries.contains(where: { $0.isProjection })
        let sessionXDomain: ClosedRange<Date>? = {
            guard xLabelStyle == .hourSuffixed, firstCurrent != nil else { return nil }
            if hasProjection {
                let start = nowHour.addingTimeInterval(-3 * 3600)
                let end = nowHour.addingTimeInterval(3600 + 50 * 60)
                return start...end
            } else {
                let start = nowHour.addingTimeInterval(-4 * 3600)
                let end = nowHour.addingTimeInterval(50 * 60)
                return start...end
            }
        }()
        // Label ticks at bucket centers — `centered: true` on stride ticks
        // silently drops the rightmost label when the next stride point is
        // outside the chart domain.
        let sessionLabelTicks: [Date] = {
            guard xLabelStyle == .hourSuffixed else { return [] }
            let leftEdgeHour = hasProjection
                ? nowHour.addingTimeInterval(-3 * 3600)
                : nowHour.addingTimeInterval(-4 * 3600)
            return (0..<5).map { i in
                leftEdgeHour.addingTimeInterval(Double(i) * 3600 + 1800)
            }
        }()
        let sessionResetBoundary: Date? = {
            guard xLabelStyle == .hourSuffixed,
                  let firstCurrent,
                  let domain = sessionXDomain,
                  firstCurrent.at > domain.lowerBound
            else { return nil }
            return firstCurrent.at
        }()
        // Explicit hour-boundary dates inside the chart domain. We build
        // this list ourselves instead of using `.stride(by: .hour)` because
        // SwiftUI Charts' stride generator can emit dates that don't exactly
        // equal the session reset boundary.
        let sessionHourBoundaries: [Date] = {
            guard xLabelStyle == .hourSuffixed,
                  let domain = sessionXDomain else { return [] }
            var out: [Date] = []
            var t = domain.lowerBound
            while t <= domain.upperBound {
                out.append(t)
                t = t.addingTimeInterval(3600)
            }
            return out
        }()

        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !warmLatest)) { context in
            // Pulse: 0..1 over a 1.8s period with cosine easing — starts at
            // 0 (full opacity), peaks at 1 (dimmed by 20% in `barColor`),
            // returns to 0. Only applied to the focal bar when warm.
            let pulseValue: Double = warmLatest ? Self.pulse(at: context.date) : 0
            chartContent(
                pulseValue: pulseValue,
                warmLatest: warmLatest,
                hasProjection: hasProjection,
                todayDay: todayDay,
                todayIdx: todayIdx,
                sessionXDomain: sessionXDomain,
                sessionLabelTicks: sessionLabelTicks,
                sessionResetBoundary: sessionResetBoundary,
                sessionHourBoundaries: sessionHourBoundaries
            )
        }
    }

    private static func pulse(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let period: Double = 1.8
        return (1 - cos(2 * .pi * t / period)) / 2
    }

    @ViewBuilder
    private func chartContent(
        pulseValue: Double,
        warmLatest: Bool,
        hasProjection: Bool,
        todayDay: Date,
        todayIdx: Int?,
        sessionXDomain: ClosedRange<Date>?,
        sessionLabelTicks: [Date],
        sessionResetBoundary: Date?,
        sessionHourBoundaries: [Date]
    ) -> some View {
        Chart {
            ForEach(displayEntries.enumerated(), id: \.element.id) { idx, e in
                BarMark(
                    x: .value("Time", e.at, unit: xStride),
                    y: .value("Usage", e.value),
                    width: .ratio(0.6)
                )
                .foregroundStyle(
                    UsageTrendChart.barColor(
                        for: e,
                        indexInDisplay: idx,
                        displayCount: displayEntries.count,
                        hasProjection: hasProjection,
                        tint: tint,
                        warmLatest: warmLatest,
                        emphasis: emphasis,
                        todayIdx: emphasis == .lastOnly ? todayIdx : nil,
                        pulseValue: pulseValue
                    )
                )
                .cornerRadius(2)
                .accessibilityLabel(UsageTrendChart.barAccessibilityLabel(entry: e, style: xLabelStyle))
                .accessibilityValue(UsageTrendChart.barAccessibilityValue(entry: e))
            }

            if let avgReference {
                RuleMark(y: .value("Average", avgReference))
                    .foregroundStyle(Color.green.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .annotation(position: .trailing, alignment: .leading) {
                        Text("avg")
                            .font(.caption2)
                            .foregroundStyle(Color.green.opacity(0.7))
                    }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXDomain(sessionXDomain)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let n = v.as(Double.self) {
                        Text("\(Int(n))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            if xLabelStyle == .hourSuffixed {
                // At the session reset boundary, render a SOLID
                // AxisGridLine — the absence of dashes reads as a
                // separator vs the dashed hour gridlines.
                AxisMarks(values: sessionHourBoundaries) { v in
                    if let date = v.as(Date.self),
                       let boundary = sessionResetBoundary,
                       abs(date.timeIntervalSince(boundary)) < 30 {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        AxisTick(length: .longestLabel,
                                 stroke: StrokeStyle(lineWidth: 0.5))
                    } else {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisTick(length: .longestLabel,
                                 stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    }
                }
                AxisMarks(values: sessionLabelTicks) { v in
                    AxisValueLabel(anchor: .top) {
                        if let date = v.as(Date.self) {
                            UsageTrendChart.xLabel(for: date.addingTimeInterval(-1800),
                                                   style: xLabelStyle,
                                                   todayDay: todayDay)
                        }
                    }
                }
            } else {
                AxisMarks(values: .stride(by: xStride)) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisTick()
                    AxisValueLabel(centered: true) {
                        if let date = v.as(Date.self) {
                            UsageTrendChart.xLabel(for: date, style: xLabelStyle, todayDay: todayDay)
                        }
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            // Reinforce the session reset boundary with a path-drawn solid
            // line that spans the full chart frame — AxisTick stroke dash
            // patterns aren't reliably honored in the label gutter.
            GeometryReader { geo in
                if let boundary = sessionResetBoundary,
                   let plotFrame = proxy.plotFrame,
                   let xInPlot = proxy.position(forX: boundary) {
                    let frameRect = geo[plotFrame]
                    let absX = frameRect.minX + xInPlot
                    Path { path in
                        path.move(to: CGPoint(x: absX, y: 0))
                        path.addLine(to: CGPoint(x: absX, y: geo.size.height))
                    }
                    .stroke(
                        Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 0.5)
                    )
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension View {
    /// Applies `chartXScale(domain:)` only when a domain is provided. The
    /// session chart fixes its x-axis to a 5h window; the weekly chart leaves
    /// the scale auto-derived.
    @ViewBuilder
    func chartXDomain(_ domain: ClosedRange<Date>?) -> some View {
        if let domain {
            self.chartXScale(domain: domain)
        } else {
            self
        }
    }
}

private struct SkeletonRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// Renders the trailing-details slot for `UsageTrendChart.section` with the
/// hairline divider above it, but only when the caller's `@ViewBuilder`
/// produced a non-empty view. `_VariadicView_MultiViewRoot` lets us inspect
/// the produced subviews; on an empty result (caller passed `EmptyView`),
/// the block emits nothing — preserving the visual identical-to-before
/// behavior of `if let trailingDetails`.
/// TODO(macos-15): replace `_VariadicView.Tree(_Root())` with
/// `Group(subviews: content()) { subviews in ... }` once the deployment
/// target bumps to macOS 15.
private struct _TrailingDetailsBlock<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        _VariadicView.Tree(_Root()) { content() }
    }

    private struct _Root: _VariadicView_MultiViewRoot {
        @ViewBuilder func body(children: _VariadicView.Children) -> some View {
            if !children.isEmpty {
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 1)
                    .padding(.top, 4)
                    .padding(.bottom, 2)

                ForEach(children) { child in
                    child
                }
                .padding(.top, 2)
            }
        }
    }
}

extension Array where Element == UsageTrendChart.Entry {
    /// Appends one projection entry one hour after the latest real entry,
    /// extrapolating from the average per-hour delta of the last 3 deltas.
    /// Skips when there's not enough data or the projection would clamp to 0.
    func appendingProjection() -> [UsageTrendChart.Entry] {
        guard count >= 2, let last = self.last else { return self }
        guard let pace = averageDeltaPerHour() else { return self }
        let next = Swift.min(100, Swift.max(0, last.value + pace))
        guard abs(next - last.value) > 0.1 else { return self }
        let nextAt = last.at.addingTimeInterval(3600)
        let projection = UsageTrendChart.Entry(at: nextAt, value: next, isProjection: true)
        let withProjection = self + [projection]
        // Session chart locks to a 5-slot visual frame (see chart() comment).
        // When sessionEntries already returned 5 bars, the projection makes 6
        // and the leftmost bar falls outside the chart domain — SwiftUI Charts
        // partially renders it and it bleeds past the left edge. Sacrifice the
        // leftmost bar to keep the count at 5, matching the documented intent.
        guard withProjection.count > 5 else { return withProjection }
        return Array(withProjection.dropFirst(withProjection.count - 5))
    }

    /// Mean of the last 3 (or fewer) hour-to-hour deltas — used both for the
    /// projection ghost and for the velocity footnote. Excludes
    /// `isPreviousSession` bars so a 5h-window reset doesn't poison the
    /// projection with a huge negative delta.
    func averageDeltaPerHour() -> Double? {
        let real = filter { !$0.isProjection && !$0.isPreviousSession }
        guard real.count >= 2 else { return nil }
        let tailCount: Int = Swift.min(4, real.count)
        let tail = real.suffix(tailCount)
        let pairs = zip(tail, tail.dropFirst())
        let deltas = pairs.map { $1.value - $0.value }
        guard !deltas.isEmpty else { return nil }
        return deltas.reduce(0, +) / Double(deltas.count)
    }
}

private extension Array where Element == UsageTrendChart.Entry {
    var average: Double? {
        guard !isEmpty else { return nil }
        return reduce(0.0) { $0 + $1.value } / Double(count)
    }

    /// Mean of cumulative values for days strictly before today — used as the
    /// weekly avg reference. Today and future days are excluded.
    var pastDaysAverage: Double? {
        // Calendar.current intentional: "past days" is computed against the
        // user's local "today", matching the chart's render anchor.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let past = filter { !$0.isFuture && !$0.isProjection && $0.at < today }
        guard !past.isEmpty else { return nil }
        return past.reduce(0) { $0 + $1.value } / Double(past.count)
    }
}
