//
//  ClaudeAPIClient.swift
//  Kwota
//
//  Single entry point for fetching usage from claude.ai.
//  Branches on Credential variant to choose Cookie vs Bearer auth.
//

import Foundation

final class ClaudeAPIClient {
    enum APIError: Error, Equatable {
        case unauthorized
        case http(status: Int)
        case decode(String)
        case noOrganizationFound
        /// Server returned 429 with no usable snapshot data (sessionKey path).
        /// `retryAfter` is the server-suggested back-off in seconds, parsed
        /// from the `Retry-After` header. Nil if absent or non-numeric.
        case rateLimited(retryAfter: TimeInterval?)
        /// Transient failure (connection refused, no server reachable, all
        /// candidate transports exhausted without a 200). Surfaced by the
        /// Antigravity local Connect-RPC client when neither HTTP nor HTTPS
        /// loopback succeeds. Callers may treat as a retryable network error.
        case transient
    }

    /// Result of a snapshot fetch that may also surface a server-driven
    /// back-off hint. Used by the Messages API path, where 429 still carries
    /// a usable snapshot in the `anthropic-ratelimit-unified-*` headers.
    struct SnapshotFetch: Equatable {
        let snapshot: UsageSnapshot
        let retryAfter: TimeInterval?
    }

    static let baseURL = URL(string: "https://claude.ai/api")!

    private static let fallbackProbeModel = "claude-haiku-4-5-20251001"

    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    let transport: Transport
    let now: () -> Date

    init(
        transport: @escaping Transport,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.now = now
    }

    /// Production transport — uses `URLSession.shared`. Must NOT be used in
    /// tests; XCTest targets should pass a stub closure to `init(transport:)`.
    ///
    /// The closure is explicitly `@Sendable` so it runs off the MainActor.
    /// The target builds `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which
    /// makes an unannotated closure implicitly @MainActor — meaning the
    /// `URLRequest → NSURLRequest` bridge inside `URLSession.data(for:)`
    /// happens in the MainActor heap context. A null-isa crash has been
    /// observed in that bridge under sustained concurrent CF traffic from
    /// FSEvents callbacks + JSONL backfill on some hosts. Forcing the
    /// transport non-isolated takes the bridge off main and onto the
    /// cooperative pool.
    static func live(now: @escaping () -> Date = Date.init) -> ClaudeAPIClient {
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { req in
            try await URLSession.shared.data(for: req)
        }
        return ClaudeAPIClient(transport: transport, now: now)
    }

    // MARK: - Subscription plan probe (sessionKey only)

    private struct BootstrapPlanResponse: Decodable {
        let account: AccountSection

        struct AccountSection: Decodable {
            /// User's full name as set in claude.ai profile. Preferred over
            /// `displayName` when populated. Both are nullable in the API.
            let fullName: String?
            /// Shorter display string Anthropic shows in the chat header.
            /// Often falls back to email-prefix when the user hasn't set a
            /// full_name. Used as a fallback when `full_name` is absent.
            let displayName: String?
            let memberships: [Membership]

            enum CodingKeys: String, CodingKey {
                case fullName = "full_name"
                case displayName = "display_name"
                case memberships
            }
        }

        struct Membership: Decodable {
            let seatTier: String?
            let organization: Org

            enum CodingKeys: String, CodingKey {
                case seatTier = "seat_tier"
                case organization
            }
        }

        struct Org: Decodable {
            let uuid: String
            let ravenType: String?
            /// `"stripe_subscription"` when an active billing subscription
            /// exists; null for Free, API-only, or unbilled orgs.
            let billingType: String?
            /// When the org was created. Best available proxy for
            /// "subscription started" since the bootstrap response doesn't
            /// expose an explicit subscription anchor. For individual
            /// Pro/Max plans the user owns the org so this == subscribe
            /// date; for Team/Enterprise this is when the team was set up.
            /// Caveat: a user who upgraded Free → Pro after creating their
            /// org will have org.created_at older than their actual
            /// subscription start. We mitigate by gating on `billing_type`
            /// (Risk 1 in design doc) so Free orgs don't surface a fake
            /// renewal date at all.
            let createdAt: Date?

            enum CodingKeys: String, CodingKey {
                case uuid
                case ravenType = "raven_type"
                case billingType = "billing_type"
                case createdAt = "created_at"
            }
        }
    }

    /// Bootstrap-derived account metadata for a sessionKey-authenticated
    /// user. Returned as a struct (instead of separate methods) because all
    /// fields come from the same /edge-api/bootstrap response — wasteful to
    /// call it more than once. Despite the historical name, this also
    /// carries the user's display name now that the wizard surfaces it.
    struct SubscriptionInfo: Equatable {
        /// Plan label like "Team" / "Pro" / "Max" / "Enterprise" / "Free".
        /// Nil when both seat_tier and raven_type are absent.
        let plan: String?
        /// When the subscription started. Nil for Free users (no
        /// subscription) and when `billing_type` is null (covered by the
        /// Risk 1 mitigation: skip createdAt for unbilled orgs so the
        /// renewal-text logic doesn't surface a fake date).
        let createdAt: Date?
        /// Human display name from `account.full_name` (preferred) or
        /// `account.display_name` (fallback). Nil when both are absent.
        /// Used to pre-fill the Add-Account confirm sheet's name draft so
        /// web-flow profiles match the labelling CLI-flow profiles already
        /// get from `oauthAccount.displayName`.
        let displayName: String?

        init(plan: String?, createdAt: Date?, displayName: String? = nil) {
            self.plan = plan
            self.createdAt = createdAt
            self.displayName = displayName
        }
    }

    /// Pure parser — exposed for unit tests. The plan field is populated
    /// from `seat_tier` (preferred) or `raven_type` (fallback) on the
    /// matching membership. The createdAt field is populated from
    /// `organization.created_at` ONLY when the membership has an active
    /// subscription (`billing_type != nil`) and isn't on Free
    /// (`seat_tier != "free"`) — Risk 1 mitigation against fake renewal
    /// dates for unbilled orgs.
    static func extractSubscriptionInfo(from data: Data, orgId: String) -> SubscriptionInfo {
        // Reuse the existing usage-payload decoder — same ISO8601 dialect
        // (with fractional seconds, e.g. "2026-04-21T05:46:15.712628Z").
        guard let decoded = try? JSONDecoder.usageDecoder().decode(BootstrapPlanResponse.self, from: data) else {
            return SubscriptionInfo(plan: nil, createdAt: nil)
        }
        guard let match = decoded.account.memberships.first(where: { $0.organization.uuid == orgId }) else {
            return SubscriptionInfo(plan: nil, createdAt: nil)
        }
        let plan: String?
        if let seat = match.seatTier {
            plan = planLabel(fromSeatTier: seat)
        } else if let raven = match.organization.ravenType {
            plan = raven.capitalized
        } else {
            plan = nil
        }
        // Gate createdAt on (billing_type != nil) AND (seat_tier != "free").
        // Free users + unbilled orgs → no renewal date. Risk 1 mitigation.
        let isFreeSeat = match.seatTier?.lowercased().hasPrefix("free") == true
        let hasBilling = match.organization.billingType != nil
        let createdAt: Date? = (hasBilling && !isFreeSeat) ? match.organization.createdAt : nil
        // Prefer full_name; fall back to display_name. Empty strings are
        // treated as "not set" so the wizard doesn't pre-fill the name
        // field with whitespace.
        let trimmed = (decoded.account.fullName ?? decoded.account.displayName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (trimmed?.isEmpty == false) ? trimmed : nil
        return SubscriptionInfo(plan: plan, createdAt: createdAt, displayName: displayName)
    }

    /// Maps Anthropic's `seat_tier` strings to the user-facing plan label.
    /// Examples: `team_bendep_nonprofit_premium` → "Team",
    /// `max_5x` → "Max", `pro` → "Pro", `free` → "Free". Unknown prefixes
    /// pass through capitalized so a future tier name doesn't silently
    /// erase plan info.
    static func planLabel(fromSeatTier seat: String) -> String {
        let s = seat.lowercased()
        if s.hasPrefix("free")       { return "Free" }
        if s.hasPrefix("pro")        { return "Pro" }
        if s.hasPrefix("team")       { return "Team" }
        if s.hasPrefix("max")        { return "Max" }
        if s.hasPrefix("enterprise") { return "Enterprise" }
        AppLog.shared.log(
            "ClaudeAPIClient.planLabel: unknown seat_tier '\(seat)' — surfacing raw capitalized",
            level: .warn
        )
        return seat.capitalized
    }

    static func makeUsageRequest(orgId: String, credential: Credential) -> URLRequest {
        let url = baseURL
            .appendingPathComponent("organizations")
            .appendingPathComponent(orgId)
            .appendingPathComponent("usage")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyCommonHeaders(to: &req)
        applyAuth(credential, to: &req)
        return req
    }

    static func makeOrganizationsRequest(credential: Credential) -> URLRequest {
        let url = baseURL.appendingPathComponent("organizations")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyCommonHeaders(to: &req)
        applyAuth(credential, to: &req)
        return req
    }

    private static func applyCommonHeaders(to req: inout URLRequest) {
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        req.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        // Honest, non-spoofed identifier. The previous Mozilla-prefixed UA
        // didn't fool any defender (no sec-fetch-* etc.) and only signaled
        // intent-to-spoof. Identifying as Kwota up-front leaves Anthropic
        // free to engage with us as a third-party client rather than treat
        // us as a bot pretending to be Safari.
        req.setValue(
            "Kwota/0.1 (+https://github.com/thanhhaudev/kwota)",
            forHTTPHeaderField: "User-Agent"
        )
    }

    /// Parses `Retry-After` from an HTTP response. Supports the integer
    /// "seconds" form; HTTP-date form is rare on Anthropic surfaces and
    /// returns nil here (caller falls back to its own default back-off).
    static func parseRetryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(raw.trimmingCharacters(in: .whitespaces)) {
            return max(0, seconds)
        }
        return nil
    }

    private static func applyAuth(_ credential: Credential, to req: inout URLRequest) {
        switch credential {
        case .sessionKey(let value):
            req.setValue("sessionKey=\(value)", forHTTPHeaderField: "Cookie")
        case .cliToken(let access, _, _):
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }
    }

    static func decodeUsage(data: Data, now: Date) throws -> UsageSnapshot {
        do {
            var snapshot = try JSONDecoder.usageDecoder().decode(UsageSnapshot.self, from: data)
            snapshot.fetchedAt = now
            return snapshot
        } catch {
            throw APIError.decode(String(describing: error))
        }
    }

    // MARK: - CLI OAuth: usage probe via api.anthropic.com/api/oauth/usage
    //
    // This is the endpoint Claude Code's own `/usage` slash command hits
    // (verified by inspecting `claude --debug api` output). Strict upgrade
    // over the previous Messages-API workaround:
    //
    //   - Free GET (no token billing per probe)
    //   - Returns the FULL JSON shape — same fields as the sessionKey
    //     claude.ai/api/usage path (five_hour, seven_day, seven_day_sonnet,
    //     seven_day_omelette, extra_usage, …) — so `decodeUsage` reuses
    //     directly and CLI profiles unlock per-model breakdown rows.
    //   - api.anthropic.com is the developer host, so no Cloudflare WAF
    //     interference (claude.ai/api/* rejects CLI Bearer at the edge).
    //   - Server returns `anthropic-organization-id` header — no separate
    //     org-id lookup round-trip needed for OAuth profiles.

    static let oauthUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// CLI/OAuth-Bearer entry point for fetching usage. Throws
    /// `APIError.unauthorized` on 401/403, `.rateLimited(retryAfter:)` on
    /// 429, `.decode` on malformed body, `.http(status:)` on 5xx/other.
    func fetchSnapshotViaOAuthUsage(credential: Credential) async throws -> SnapshotFetch {
        guard case .cliToken = credential else {
            throw APIError.unauthorized
        }
        var req = URLRequest(url: Self.oauthUsageURL)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        Self.applyAuth(credential, to: &req)
        // Honest UA — same identifier we use on claude.ai paths so Anthropic
        // logs see one client, not two. We do NOT call applyCommonHeaders
        // here because that sets Origin/Referer for claude.ai; this endpoint
        // is api.anthropic.com (developer host) and those headers shouldn't
        // be sent.
        req.setValue(
            "Kwota/0.1 (+https://github.com/thanhhaudev/kwota)",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await transport(req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(status: -1)
        }
        switch http.statusCode {
        case 200...299:
            return SnapshotFetch(
                snapshot: try Self.decodeUsage(data: data, now: now()),
                retryAfter: nil
            )
        case 401, 403:
            throw APIError.unauthorized
        case 429:
            // Free-GET endpoint — 429 is rare (only on degraded API). Body
            // isn't usable; back off via Retry-After like the sessionKey
            // path does.
            throw APIError.rateLimited(retryAfter: Self.parseRetryAfter(http))
        default:
            throw APIError.http(status: http.statusCode)
        }
    }

    // MARK: - CLI OAuth: legacy Messages-API workaround (disabled 2026-05-08)
    //
    // BEFORE we discovered `/api/oauth/usage`, the only way to get any
    // usage signal for CLI Bearer was a 1-token POST to /v1/messages and
    // reading `anthropic-ratelimit-unified-{5h,7d}-*` response headers.
    // After the CLI-only scope cut this path is wrapped in /* ... */
    // below for revival reference, and the matching tests in
    // ClaudeAPIClientTests are XCTSkip-disabled with their bodies
    // preserved. Re-enabling means uncommenting the method body and the
    // test bodies in lockstep, then re-wiring `MenuBarViewModel.refresh`
    // to call this if Anthropic ever closes /api/oauth/usage to non-CLI
    // clients. Caveats vs the new endpoint: costs 1 token per probe, no
    // per-model fields, depends on `unified-*` headers that aren't on the
    // public rate-limits doc.

    static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!

    // Cache → AI evaluation moved out of this file on 2026-05-21. Anthropic
    // gates third-party OAuth-Bearer use of `/v1/messages`, so the only
    // working path for arbitrary message generation is shelling out to
    // `claude -p` via `ClaudeCLIRunner`. See `CacheEvaluator`.

}
