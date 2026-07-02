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
    /// "Fable only" weekly bucket. Unlike its siblings this has no top-level
    /// `seven_day_fable` key in the API payload — since 2026-07 the per-model
    /// quota ships inside the `limits` array as a `weekly_scoped` entry whose
    /// `scope.model.display_name` is "Fable" (the older `seven_day_*` model
    /// keys all went null at the same time). Decoding falls back to that
    /// array; if the display name rotates, the field decodes to nil and the
    /// row disappears — same graceful degradation as `sevenDayOmelette`.
    /// Cached snapshots (profiles.json) round-trip through the direct
    /// `seven_day_fable` key we encode ourselves.
    let sevenDayFable: UsageBucket?
    let extra: ExtraUsage?
    var fetchedAt: Date

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOmelette = "seven_day_omelette"
        case sevenDayFable = "seven_day_fable"
        case extra = "extra_usage"
        case fetchedAt
    }

    /// API-payload-only keys, kept out of `CodingKeys` so the auto-generated
    /// `encode(to:)` (cached snapshots) never writes them.
    private enum APIOnlyKeys: String, CodingKey {
        case limits
    }

    init(
        fiveHour: UsageBucket,
        sevenDay: UsageBucket,
        sevenDayOpus: UsageBucket? = nil,
        sevenDaySonnet: UsageBucket? = nil,
        sevenDayOmelette: UsageBucket? = nil,
        sevenDayFable: UsageBucket? = nil,
        extra: ExtraUsage? = nil,
        fetchedAt: Date = .distantPast
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.sevenDayOmelette = sevenDayOmelette
        self.sevenDayFable = sevenDayFable
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
            sevenDayFable: nil,
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
        // Direct key first (cached snapshots), then the API's limits array.
        self.sevenDayFable = try c.decodeIfPresent(UsageBucket.self, forKey: .sevenDayFable)
            ?? Self.scopedWeeklyBucket(modelDisplayName: "Fable", from: decoder)
        self.extra = try c.decodeIfPresent(ExtraUsage.self, forKey: .extra)
        // API responses don't include fetchedAt (stamped by client after decode).
        // Cached snapshots persisted in profiles.json do — decode if present.
        self.fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
    }

    /// Minimal projection of one `limits[]` entry — every field optional so a
    /// shape drift degrades to "no per-model row" instead of failing the
    /// whole snapshot decode.
    private struct ScopedLimit: Decodable {
        let kind: String?
        let percent: Double?
        let resetsAt: Date?
        let scope: Scope?

        struct Scope: Decodable {
            let model: Model?
        }

        struct Model: Decodable {
            let displayName: String?

            private enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
        }
    }

    /// Per-model weekly quota from the `limits` array: the first
    /// `weekly_scoped` entry whose `scope.model.display_name` matches
    /// (case-insensitive). All failures collapse to nil by design.
    private static func scopedWeeklyBucket(
        modelDisplayName: String,
        from decoder: Decoder
    ) -> UsageBucket? {
        guard let c = try? decoder.container(keyedBy: APIOnlyKeys.self),
              let limits = (try? c.decodeIfPresent([ScopedLimit].self, forKey: .limits)) ?? nil,
              let entry = limits.first(where: {
                  $0.kind == "weekly_scoped"
                      && $0.scope?.model?.displayName?
                          .caseInsensitiveCompare(modelDisplayName) == .orderedSame
              })
        else { return nil }
        return UsageBucket(utilization: entry.percent, resetsAt: entry.resetsAt)
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

    func effectiveSevenDayFable(now: Date = Date()) -> UsageBucket? {
        sevenDayFable.map { Self.clamp($0, now: now) }
    }

    private static func clamp(_ bucket: UsageBucket, now: Date) -> UsageBucket {
        guard let resetsAt = bucket.resetsAt, resetsAt < now else { return bucket }
        return UsageBucket(utilization: 0, resetsAt: resetsAt)
    }
}
