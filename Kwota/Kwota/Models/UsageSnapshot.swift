//
//  UsageSnapshot.swift
//  Kwota
//

import Foundation

struct UsageSnapshot: Codable, Equatable {
    let fiveHour: UsageBucket
    let sevenDay: UsageBucket
    let sevenDayOpus: UsageBucket?
    let sevenDaySonnet: UsageBucket?
    /// "Claude Design" weekly bucket. JSON key uses Anthropic's internal
    /// codename `seven_day_omelette`; if Anthropic ever rotates the codename
    /// the field decodes to nil and the row disappears from the UI — that is
    /// the intended graceful-degradation behavior. Re-map the CodingKey when
    /// the rotation lands.
    let sevenDayOmelette: UsageBucket?
    let extra: ExtraUsage?
    var fetchedAt: Date

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOmelette = "seven_day_omelette"
        case extra = "extra_usage"
        case fetchedAt
    }

    init(
        fiveHour: UsageBucket,
        sevenDay: UsageBucket,
        sevenDayOpus: UsageBucket? = nil,
        sevenDaySonnet: UsageBucket? = nil,
        sevenDayOmelette: UsageBucket? = nil,
        extra: ExtraUsage? = nil,
        fetchedAt: Date = .distantPast
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.sevenDayOmelette = sevenDayOmelette
        self.extra = extra
        self.fetchedAt = fetchedAt
    }

    /// Placeholder used while the first fetch is in flight. All buckets at 0%
    /// and `fetchedAt = .distantPast` so callers can detect "not real data yet".
    static func zeroes(now: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(5 * 3600)),
            sevenDay: UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(7 * 86400)),
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayOmelette: nil,
            extra: nil,
            fetchedAt: .distantPast
        )
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.fiveHour = try c.decode(UsageBucket.self, forKey: .fiveHour)
        self.sevenDay = try c.decode(UsageBucket.self, forKey: .sevenDay)
        self.sevenDayOpus = try c.decodeIfPresent(UsageBucket.self, forKey: .sevenDayOpus)
        self.sevenDaySonnet = try c.decodeIfPresent(UsageBucket.self, forKey: .sevenDaySonnet)
        self.sevenDayOmelette = try c.decodeIfPresent(UsageBucket.self, forKey: .sevenDayOmelette)
        self.extra = try c.decodeIfPresent(ExtraUsage.self, forKey: .extra)
        // API responses don't include fetchedAt (stamped by client after decode).
        // Cached snapshots persisted in profiles.json do — decode if present.
        self.fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
    }
}

// MARK: - Effective buckets (clamp utilization to 0 once the window has reset)
//
// Source-of-truth at decode time is `decodeRateLimitHeaders`, which already
// clamps `fiveHour` when its `resetsAt` is in the past. UI consumers must
// apply the same rule when reading a *cached* snapshot — its window may have
// reset between fetch time and display time. The `.sessionKey` decoder
// (`decodeUsage`) does not clamp at decode time, so this is also the only
// layer where `.sessionKey` snapshots get the same treatment.

extension UsageSnapshot {
    func effectiveFiveHour(now: Date = Date()) -> UsageBucket {
        Self.clamp(fiveHour, now: now)
    }

    func effectiveSevenDay(now: Date = Date()) -> UsageBucket {
        Self.clamp(sevenDay, now: now)
    }

    func effectiveSevenDayOpus(now: Date = Date()) -> UsageBucket? {
        sevenDayOpus.map { Self.clamp($0, now: now) }
    }

    func effectiveSevenDaySonnet(now: Date = Date()) -> UsageBucket? {
        sevenDaySonnet.map { Self.clamp($0, now: now) }
    }

    func effectiveSevenDayOmelette(now: Date = Date()) -> UsageBucket? {
        sevenDayOmelette.map { Self.clamp($0, now: now) }
    }

    private static func clamp(_ bucket: UsageBucket, now: Date) -> UsageBucket {
        guard let resetsAt = bucket.resetsAt, resetsAt < now else { return bucket }
        return UsageBucket(utilization: 0, resetsAt: resetsAt)
    }
}
