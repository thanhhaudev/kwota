//
//  OAuthAccountReader.swift
//  Kwota
//
//  Reads Claude Code's ~/.claude.json `oauthAccount` block. Source of truth for
//  the user's plan (`seatTier`), email, display name, and org name.
//

import Foundation

struct OAuthAccountReader {
    typealias Provider = () -> Data?

    let configFile: URL
    private let provider: Provider?

    init(configFile: URL = OAuthAccountReader.defaultPath, provider: Provider? = nil) {
        self.configFile = configFile
        self.provider = provider
    }

    static var defaultPath: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    struct Account: Equatable {
        let seatTier: String?
        let emailAddress: String?
        let displayName: String?
        let organizationName: String?
        let subscriptionCreatedAt: Date?
        let organizationType: String?
        let organizationRateLimitTier: String?
        let accountUuid: String?
        let organizationUuid: String?

        /// Convenience init: new fields default to nil so existing callers compile without changes.
        init(
            seatTier: String?,
            emailAddress: String?,
            displayName: String?,
            organizationName: String?,
            subscriptionCreatedAt: Date?,
            organizationType: String? = nil,
            organizationRateLimitTier: String? = nil,
            accountUuid: String? = nil,
            organizationUuid: String? = nil
        ) {
            self.seatTier = seatTier
            self.emailAddress = emailAddress
            self.displayName = displayName
            self.organizationName = organizationName
            self.subscriptionCreatedAt = subscriptionCreatedAt
            self.organizationType = organizationType
            self.organizationRateLimitTier = organizationRateLimitTier
            self.accountUuid = accountUuid
            self.organizationUuid = organizationUuid
        }
    }

    func read() -> Account? {
        let data: Data?
        if let provider {
            data = provider()
        } else {
            data = try? Data(contentsOf: configFile)
        }
        guard
            let data,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["oauthAccount"] as? [String: Any]
        else {
            return nil
        }
        let subscriptionCreatedAt: Date? = (oauth["subscriptionCreatedAt"] as? String)
            .flatMap(ISO8601DateFormatter.fractional.date(from:))
        return Account(
            seatTier: oauth["seatTier"] as? String,
            emailAddress: oauth["emailAddress"] as? String,
            displayName: oauth["displayName"] as? String,
            organizationName: oauth["organizationName"] as? String,
            subscriptionCreatedAt: subscriptionCreatedAt,
            organizationType: oauth["organizationType"] as? String,
            organizationRateLimitTier: oauth["organizationRateLimitTier"] as? String,
            accountUuid: oauth["accountUuid"] as? String,
            organizationUuid: oauth["organizationUuid"] as? String
        )
    }
}

private extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Maps Claude Code's `seatTier`, `organizationType`, or `/api/oauth/profile`'s
/// `organization.rate_limit_tier` to a human-readable plan label.
///
/// All entry points funnel into `renderPlan(baseToken:suffixTokens:)` so the
/// suffix-formatting rule (append `\d+x` and `premium`, drop the rest) stays
/// consistent across CLI and API sources.
enum PlanFormatter {
    /// Legacy single-arg entry point — splits `raw` by `_` and renders.
    /// Used for `oauthAccount.seatTier`, CLI keychain `subscriptionType`,
    /// and the `organizationType` fallback inside the two-arg overload.
    static func format(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let tokens = raw.lowercased().split(separator: "_").map(String.init)
        guard let base = tokens.first else { return nil }
        return renderPlan(baseToken: base, suffixTokens: Array(tokens.dropFirst()))
    }

    /// Two-arg overload: tries `seatTier` first; falls back to `organizationType`
    /// with a leading `claude_` stripped. Keeps the existing precedence
    /// (`seatTier` wins) so paid Team accounts where Anthropic populates
    /// `seat_tier` keep their richer label.
    static func format(seatTier: String?, organizationType: String?) -> String? {
        if let formatted = format(seatTier) { return formatted }
        guard let raw = organizationType, !raw.isEmpty else { return nil }
        let stripped = raw.hasPrefix("claude_") ? String(raw.dropFirst("claude_".count)) : raw
        return format(stripped)
    }

    /// New entry point for `/api/oauth/profile`'s `organization.rate_limit_tier`
    /// (e.g. `default_claude_max_20x`, `default_claude_team_premium`). The
    /// `default_claude_` (or just `claude_`) prefix is stripped; everything
    /// after the base plan token is treated as suffix.
    static func format(rateLimitTier raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var stripped = raw.lowercased()
        if stripped.hasPrefix("default_claude_") {
            stripped = String(stripped.dropFirst("default_claude_".count))
        } else if stripped.hasPrefix("claude_") {
            stripped = String(stripped.dropFirst("claude_".count))
        }
        let tokens = stripped.split(separator: "_").map(String.init)
        guard let base = tokens.first, !base.isEmpty else { return nil }
        return renderPlan(baseToken: base, suffixTokens: Array(tokens.dropFirst()))
    }

    /// Maps the base token to a display label and appends only the suffix
    /// tokens that are visibly meaningful: `\d+x` (Max rate multipliers) and
    /// `premium` (Team Premium). Other tokens (org slugs, account flavors)
    /// are dropped. Unknown bases capitalize the first character and log a
    /// warning so future tier names surface in logs without crashing the UI.
    private static func renderPlan(baseToken: String, suffixTokens: [String]) -> String {
        let baseLabel: String
        switch baseToken {
        case "free":       baseLabel = "Free"
        case "plus":       baseLabel = "Plus"        // ChatGPT Plus (Codex)
        case "pro":        baseLabel = "Pro"
        case "team":       baseLabel = "Team"
        case "max":        baseLabel = "Max"
        case "enterprise": baseLabel = "Enterprise"
        case "raven":      baseLabel = "Pro"  // legacy alias
        default:
            AppLog.shared.log(
                "PlanFormatter: unrecognized base token \"\(baseToken)\"",
                level: .warn
            )
            baseLabel = baseToken.prefix(1).uppercased() + baseToken.dropFirst()
        }
        var label = baseLabel
        for token in suffixTokens {
            if token.range(of: #"^\d+x$"#, options: .regularExpression) != nil {
                label += " " + token
            } else if token == "premium" {
                label += " Premium"
            }
            // Other tokens dropped silently.
        }
        return label
    }
}
