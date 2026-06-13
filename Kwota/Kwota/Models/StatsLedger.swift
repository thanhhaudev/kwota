//
//  StatsLedger.swift
//  Kwota
//

import Foundation

/// Persisted rollup of token consumption: provider → UTC day → model →
/// `TokenBreakdown`. Pure value type with no IO — `StatsStore` owns
/// persistence. Day keys are UTC-anchored for the same reason as
/// `UsageLedger`: the on-disk aggregate must be invariant under the user's
/// timezone, or cross-tz travel reshuffles past buckets.
struct StatsLedger: Codable, Equatable {
    /// providerRawValue → dayKey("yyyy-MM-dd", UTC) → modelKey → tokens
    private(set) var byProvider: [String: [String: [String: TokenBreakdown]]] = [:]
    private(set) var lastUpdate: Date = .distantPast
    private(set) var schemaVersion: Int = 1

    static let utcCalendarForKeys: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal
    }()

    init() {}

    private enum CodingKeys: String, CodingKey { case byProvider, lastUpdate, schemaVersion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.byProvider = try c.decodeIfPresent([String: [String: [String: TokenBreakdown]]].self, forKey: .byProvider) ?? [:]
        self.lastUpdate = try c.decodeIfPresent(Date.self, forKey: .lastUpdate) ?? .distantPast
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    mutating func merge(provider: ProviderID, day: String, model: String, delta: TokenBreakdown, now: Date) {
        guard delta != .zero else { return }
        let p = provider.rawValue
        let modelKey = model.isEmpty ? "unknown" : model
        var days = byProvider[p] ?? [:]
        var models = days[day] ?? [:]
        models[modelKey] = (models[modelKey] ?? .zero) + delta
        days[day] = models
        byProvider[p] = days
        lastUpdate = now
    }

    /// Sum across all days >= `sinceDay` (nil = all days) and all models.
    func total(provider: ProviderID, sinceDay: String?) -> TokenBreakdown {
        totalsByModel(provider: provider, sinceDay: sinceDay).values.reduce(.zero, +)
    }

    /// Per-model totals across all days >= `sinceDay` (nil = all days).
    func totalsByModel(provider: ProviderID, sinceDay: String?) -> [String: TokenBreakdown] {
        guard let days = byProvider[provider.rawValue] else { return [:] }
        var out: [String: TokenBreakdown] = [:]
        for (day, models) in days where sinceDay == nil || day >= sinceDay! {
            for (model, tokens) in models { out[model] = (out[model] ?? .zero) + tokens }
        }
        return out
    }

    func dayKey(for date: Date, calendar: Calendar = StatsLedger.utcCalendarForKeys) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Hour bucket key "yyyy-MM-dd HH" (UTC). Same lexical = chronological
    /// ordering as `dayKey`, and `hasPrefix(dayKey + " ")` selects one day.
    func hourKey(for date: Date, calendar: Calendar = StatsLedger.utcCalendarForKeys) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH"
        return f.string(from: date)
    }

    /// Days >= `sinceDay` (nil = all), ascending by day key. Each entry maps
    /// model → tokens for that day. Drives the daily chart.
    func dailySeries(provider: ProviderID, sinceDay: String?) -> [(day: String, byModel: [String: TokenBreakdown])] {
        guard let days = byProvider[provider.rawValue] else { return [] }
        return days
            .filter { sinceDay == nil || $0.key >= sinceDay! }
            .sorted { $0.key < $1.key }
            .map { (day: $0.key, byModel: $0.value) }
    }

    /// Drops all recorded data for one provider (user-triggered clear). Other
    /// providers are untouched.
    mutating func clear(provider: ProviderID, now: Date) {
        byProvider[provider.rawValue] = nil
        lastUpdate = now
    }

    /// Drops day buckets older than `days` across every provider. Cutoff is
    /// computed in `calendar`'s timezone (UTC by default, matching `dayKey`).
    mutating func prune(olderThan days: Int, now: Date, calendar: Calendar = StatsLedger.utcCalendarForKeys) {
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { return }
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        for (provider, daysMap) in byProvider {
            var kept = daysMap
            for key in daysMap.keys {
                if let d = parser.date(from: key), d < cutoff { kept.removeValue(forKey: key) }
            }
            byProvider[provider] = kept
        }
    }

    /// Drops buckets whose key sorts strictly before `key` (lexicographic). The
    /// hourly rollup uses this to keep a bounded recent window — "yyyy-MM-dd HH"
    /// keys sort chronologically as plain strings.
    mutating func prune(beforeKey key: String) {
        for (provider, buckets) in byProvider {
            byProvider[provider] = buckets.filter { $0.key >= key }
        }
    }
}
