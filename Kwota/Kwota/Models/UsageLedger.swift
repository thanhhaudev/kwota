//
//  UsageLedger.swift
//  Kwota
//

import Foundation

struct UsageLedger: Codable, Equatable {
    private(set) var seenUUIDs: Set<String> = []
    private(set) var dailyByDay: [String: TokenBreakdown] = [:]
    private(set) var lastUpdate: Date = .distantPast
    /// Bumped to 2 when day-bucket keys switched from local-tz to UTC. Persisted
    /// ledgers with `schemaVersion < 2` (or missing — treated as 1 by the custom
    /// decoder below) must be dropped on load: their keys are local-tz formatted
    /// and would mis-merge with new UTC keys after cross-tz travel.
    private(set) var schemaVersion: Int = 2

    /// UTC calendar used for day-bucket keys. The persistence layer must be
    /// invariant under the user's timezone — a user flying from Vietnam (GMT+7)
    /// to the US (GMT-7) cannot have past event buckets shift by a day, or
    /// `dailyByDay` will merge totals from two different calendar days into one
    /// key (and split a single calendar day across two). Render-time code
    /// (charts, labels) keeps using `Calendar.current` so "today" matches the
    /// user's clock; only the on-disk keys are anchored to UTC.
    static let utcCalendarForKeys: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal
    }()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case dailyByDay, lastUpdate, schemaVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // seenUUIDs is in-memory only as of schemaVersion 3. Legacy v2 files
        // contain the field as a top-level array; the new CodingKeys
        // intentionally omit it, so any persisted set is silently dropped on
        // load. Within-session dedup rebuilds the Set from the JSONL replay
        // that occurs immediately after restoring reader offsets (which
        // emits zero events for files unchanged since last persist).
        self.seenUUIDs = []
        self.dailyByDay = try c.decodeIfPresent([String: TokenBreakdown].self, forKey: .dailyByDay) ?? [:]
        self.lastUpdate = try c.decodeIfPresent(Date.self, forKey: .lastUpdate) ?? .distantPast
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    /// Inserts events whose uuid is not already in `seenUUIDs`. Returns the newly
    /// inserted events (the caller — `UsageMonitor` — uses these to compute the
    /// session-since-launch delta).
    @discardableResult
    mutating func ingest(events: [UsageEvent], now: Date) -> [UsageEvent] {
        var inserted: [UsageEvent] = []
        for event in events {
            guard seenUUIDs.insert(event.uuid).inserted else { continue }
            let key = dayKey(for: event.timestamp)
            dailyByDay[key, default: .zero] = (dailyByDay[key] ?? .zero) + event.tokens
            inserted.append(event)
        }
        if !inserted.isEmpty { lastUpdate = now }
        return inserted
    }

    /// Read-only check used by tests / consumers to ask "would these events be new?"
    func ingestPreview(events: [UsageEvent]) -> [UsageEvent] {
        events.filter { !seenUUIDs.contains($0.uuid) }
    }

    func dailyBillable(day: String) -> Int {
        dailyByDay[day]?.billable ?? 0
    }

    /// Returns "yyyy-MM-dd" key for `date`, anchored to `calendar`'s timezone.
    /// Default is UTC: persistence-layer keys must not depend on the user's
    /// current timezone, otherwise cross-tz travel reshuffles past buckets and
    /// `dailyByDay` merges become incorrect. Callers that want a user-local
    /// label (chart axis, "today" string) should pass an explicit calendar.
    func dayKey(for date: Date, calendar: Calendar = UsageLedger.utcCalendarForKeys) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Drops day-buckets older than `days`. `seenUUIDs` is in-memory only
    /// and never pruned here — it grows during the session and is dropped
    /// on next launch. Reader offset persistence (in `UsageMonitor`) is the
    /// cross-restart dedup mechanism. Cutoff is computed in `calendar`'s
    /// timezone — defaults to UTC to match `dayKey`.
    mutating func prune(olderThan days: Int, now: Date, calendar: Calendar = UsageLedger.utcCalendarForKeys) {
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { return }
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        for key in dailyByDay.keys {
            if let d = parser.date(from: key), d < cutoff {
                dailyByDay.removeValue(forKey: key)
            }
        }
    }
}
