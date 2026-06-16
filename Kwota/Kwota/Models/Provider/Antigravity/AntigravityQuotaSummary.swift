//
//  AntigravityQuotaSummary.swift
//  Kwota
//
//  Decoded shape of RetrieveUserQuotaSummary from the Antigravity
//  language_server. This is the AUTHORITATIVE quota the Antigravity app's
//  "Model Quota" page displays — two model groups (Gemini, Claude+GPT), each
//  sharing a weekly limit and a 5-hour limit. Supersedes the per-model
//  `quotaInfo.remainingFraction` in GetUserStatus, which measured a different
//  (internal) throttle and showed wrong numbers to the user.
//

import Foundation

struct AntigravityQuotaSummary: Decodable, Equatable, Sendable {
    /// Stamped post-decode by the API client (mirrors the snapshot pattern).
    var fetchedAt: Date
    let groups: [Group]
    /// The server's explanatory blurb shown under the quota page.
    let description: String?

    enum Window: String, Decodable, Sendable, Equatable {
        case weekly
        case fiveHour
        case unknown

        init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
            switch raw {
            case "weekly": self = .weekly
            case "5h":     self = .fiveHour
            default:       self = .unknown
            }
        }
    }

    struct Bucket: Decodable, Equatable, Sendable {
        let bucketId: String?
        let displayName: String?
        let window: Window
        /// 0…1 of headroom remaining (1 = full). nil → unknown.
        let remainingFraction: Double?
        let resetTime: Date?

        /// 0…100 consumed — the app-wide `UsageBucket.utilization` convention.
        var utilization: Double? {
            remainingFraction.map { max(0, min(100, (1 - $0) * 100)) }
        }

        /// No headroom left — the window is fully consumed. A known
        /// `remainingFraction` of 0 (or less) means exhausted; an unknown
        /// fraction is treated as not-exhausted so we never over-claim.
        var isExhausted: Bool { (remainingFraction ?? 1) <= 0 }

        enum CodingKeys: String, CodingKey {
            case bucketId, displayName, window, remainingFraction, resetTime
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bucketId = try c.decodeIfPresent(String.self, forKey: .bucketId)
            displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            window = (try? c.decode(Window.self, forKey: .window)) ?? .unknown
            remainingFraction = try c.decodeIfPresent(Double.self, forKey: .remainingFraction)
            if let s = try c.decodeIfPresent(String.self, forKey: .resetTime) {
                resetTime = AntigravityQuotaSummary.iso.date(from: s)
            } else {
                resetTime = nil
            }
        }
        init(bucketId: String?, displayName: String?, window: Window,
             remainingFraction: Double?, resetTime: Date?) {
            self.bucketId = bucketId; self.displayName = displayName
            self.window = window; self.remainingFraction = remainingFraction
            self.resetTime = resetTime
        }
    }

    struct Group: Decodable, Equatable, Sendable {
        let displayName: String?
        let description: String?
        let buckets: [Bucket]

        var weekly: Bucket? { buckets.first { $0.window == .weekly } }
        var fiveHour: Bucket? { buckets.first { $0.window == .fiveHour } }

        /// Most-consumed window in this group → drives the picker severity dot.
        var worstUtilization: Double? {
            buckets.compactMap { $0.utilization }.max()
        }

        /// Stable identity across refreshes (picker selection + history file
        /// naming) without hardcoding model→group mapping. Prefer the bucketId
        /// prefix ("gemini-weekly" → "gemini", "3p-5h" → "3p"); fall back to a
        /// slug of the displayName.
        var key: String { AntigravityQuotaGroupKey.derive(group: self) }

        enum CodingKeys: String, CodingKey { case displayName, description, buckets }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            buckets = (try? c.decodeIfPresent([Bucket].self, forKey: .buckets)) ?? []
        }
        init(displayName: String?, description: String?, buckets: [Bucket]) {
            self.displayName = displayName; self.description = description
            self.buckets = buckets
        }
    }

    // MARK: - Decoding (wrapped in {"response":{...}})

    enum OuterKeys: String, CodingKey { case response }
    enum ResponseKeys: String, CodingKey { case groups, description }

    init(from decoder: Decoder) throws {
        fetchedAt = Date(timeIntervalSince1970: 0)
        guard let outer = try? decoder.container(keyedBy: OuterKeys.self),
              let r = try? outer.nestedContainer(keyedBy: ResponseKeys.self, forKey: .response) else {
            groups = []; description = nil; return
        }
        groups = (try? r.decodeIfPresent([Group].self, forKey: .groups)) ?? []
        description = try? r.decodeIfPresent(String.self, forKey: .description)
    }
    init(fetchedAt: Date, groups: [Group], description: String? = nil) {
        self.fetchedAt = fetchedAt; self.groups = groups; self.description = description
    }

    static let iso = ISO8601DateFormatter()
    static let decoder = JSONDecoder()

    // MARK: - Convenience (switcher + picker)

    /// Worst (most-consumed) 5h bucket across both groups + its group.
    var worstFiveHour: (group: Group, bucket: Bucket)? {
        groups.compactMap { g in g.fiveHour.map { (g, $0) } }
            .max(by: { ($0.1.utilization ?? -1) < ($1.1.utilization ?? -1) })
    }
    /// Worst (most-consumed) weekly bucket across both groups + its group.
    var worstWeekly: (group: Group, bucket: Bucket)? {
        groups.compactMap { g in g.weekly.map { (g, $0) } }
            .max(by: { ($0.1.utilization ?? -1) < ($1.1.utilization ?? -1) })
    }
    /// Key of the most-constrained group — the picker's default selection and
    /// the group the switcher is effectively warning about.
    var bindingGroupKey: String? {
        groups.max(by: { ($0.worstUtilization ?? -1) < ($1.worstUtilization ?? -1) })?.key
    }
}

/// Derives a stable per-group key from the quota payload. Kept separate so it
/// can be unit-tested and reused by the per-group history file naming.
enum AntigravityQuotaGroupKey {
    static func derive(group: AntigravityQuotaSummary.Group) -> String {
        if let id = group.buckets.first?.bucketId, !id.isEmpty {
            if let dash = id.firstIndex(of: "-") {
                return String(id[..<dash]).lowercased()
            }
            return id.lowercased()
        }
        let slug = (group.displayName ?? "group")
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return slug.isEmpty ? "group" : slug
    }
}
