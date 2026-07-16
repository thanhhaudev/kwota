//
//  CodexUsageSnapshot.swift
//  Kwota
//
//  Codable model for `chatgpt.com/backend-api/wham/usage` responses.
//  Every field is optional: OpenAI may rename, add, or drop keys without
//  notice, and we degrade gracefully (UI hides the affected card / row)
//  rather than crash.
//

import Foundation

struct CodexUsageSnapshot: Codable, Equatable, Sendable {
    var planType: String?
    var rateLimit: RateLimit?
    var codeReviewRateLimit: Window?
    var credits: Credits?
    /// Stamped client-side after decode. Used by the history append and the
    /// "Updated X seconds ago" footer. Not present on the wire.
    var fetchedAt: Date = .distantPast

    struct RateLimit: Codable, Equatable, Sendable {
        var primaryWindow: Window?
        var secondaryWindow: Window?

        private enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }

        /// Session-window duration ceiling. The 5-hour burst window (18_000s)
        /// falls well under it; the weekly limit window (604_800s) well over.
        /// One day is a deliberately loose boundary — it leaves headroom for
        /// OpenAI to resize the burst window (e.g. to 12h) without the window
        /// being misclassified as a weekly limit.
        private static let sessionWindowCeiling: Double = 86_400

        /// See `CodexUsageSnapshot.classifiedWindows`. Walks the two slots in
        /// their historical order (primary first) so that windows lacking a
        /// declared `limit_window_seconds` fall back to slot meaning: an
        /// undated window fills the still-empty session slot before weekly,
        /// matching how legacy payloads (5-hour in primary) decoded. When both
        /// windows land on the same side of the ceiling, the tie-break keeps
        /// the assignment deterministic instead of dropping data.
        var classifiedWindows: (session: Window?, weekly: Window?) {
            var session: Window?
            var weekly: Window?
            for window in [primaryWindow, secondaryWindow].compactMap({ $0 }) {
                let isSession = (window.limitWindowSeconds ?? 0) < Self.sessionWindowCeiling
                if isSession {
                    if session == nil { session = window } else if weekly == nil { weekly = window }
                } else {
                    if weekly == nil { weekly = window } else if session == nil { session = window }
                }
            }
            return (session, weekly)
        }
    }

    struct Window: Codable, Equatable, Sendable {
        var usedPercent: Double?
        var limitWindowSeconds: Double?
        var resetAt: Date?

        private enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
        }
    }

    struct Credits: Codable, Equatable, Sendable {
        var hasCredits: Bool?
        var unlimited: Bool?
        var balance: Double?

        private enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
        }

        init(hasCredits: Bool? = nil, unlimited: Bool? = nil, balance: Double? = nil) {
            self.hasCredits = hasCredits
            self.unlimited = unlimited
            self.balance = balance
        }

        /// wham/usage observed to return `balance` as a string (e.g. "12.34")
        /// for paid plans while older fixtures used a number; accept both so
        /// schema drift on either side doesn't blank the popover again.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.hasCredits = try c.decodeIfPresent(Bool.self, forKey: .hasCredits)
            self.unlimited = try c.decodeIfPresent(Bool.self, forKey: .unlimited)
            if let d = try? c.decode(Double.self, forKey: .balance) {
                self.balance = d
            } else if let s = try? c.decode(String.self, forKey: .balance) {
                self.balance = Double(s)
            } else {
                self.balance = nil
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
        case credits
        case fetchedAt
    }

    /// The 5-hour "session" window and the 7-day "weekly" window, resolved by
    /// each window's own `limit_window_seconds` rather than by which slot
    /// (`primary_window` / `secondary_window`) it arrived in.
    ///
    /// OpenAI historically shipped the 5-hour window in `primary_window`
    /// (`limit_window_seconds == 18_000`) and the weekly window in
    /// `secondary_window` (`604_800`). As of 2026-07 they collapsed the model:
    /// `primary_window` now carries the WEEKLY window and `secondary_window`
    /// is `null`. Trusting slot position therefore rendered weekly usage in the
    /// "Current Session" card (wrong 5-hour label, ~6-day countdown) and blanked
    /// the Weekly card. Classifying by duration adapts to whichever shape the
    /// server sends — one window or two, in either slot — and recovers
    /// automatically if OpenAI restores the 5-hour window later.
    var classifiedWindows: (session: Window?, weekly: Window?) {
        rateLimit?.classifiedWindows ?? (session: nil, weekly: nil)
    }

    init(
        planType: String? = nil,
        rateLimit: RateLimit? = nil,
        codeReviewRateLimit: Window? = nil,
        credits: Credits? = nil,
        fetchedAt: Date = .distantPast
    ) {
        self.planType = planType
        self.rateLimit = rateLimit
        self.codeReviewRateLimit = codeReviewRateLimit
        self.credits = credits
        self.fetchedAt = fetchedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.planType = try c.decodeIfPresent(String.self, forKey: .planType)
        self.rateLimit = try c.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
        self.codeReviewRateLimit = try c.decodeIfPresent(Window.self, forKey: .codeReviewRateLimit)
        self.credits = try c.decodeIfPresent(Credits.self, forKey: .credits)
        // wham/usage doesn't include fetchedAt; persisted snapshots may.
        self.fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
    }

    /// Shared decoder. Accepts both Unix epoch numbers (the shape `wham/usage`
    /// currently emits for `reset_at` — observed live in 2026-05) and ISO8601
    /// strings (used by persisted snapshots from earlier app builds and
    /// matches `JSONDecoder.usageDecoder()` on the Claude side).
    static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let epoch = try? c.decode(Double.self) {
                return Date(timeIntervalSince1970: epoch)
            }
            let s = try c.decode(String.self)
            let formatters: [ISO8601DateFormatter] = [
                {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f
                }(),
                {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime]
                    return f
                }()
            ]
            for f in formatters {
                if let d = f.date(from: s) { return d }
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date: \(s)")
        }
        return dec
    }()
}
