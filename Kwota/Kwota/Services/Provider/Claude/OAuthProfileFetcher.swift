//
//  OAuthProfileFetcher.swift
//  Kwota

import Foundation

/// Seam so `AutoProfileCoordinator` can inject a stub during tests without
/// hitting api.anthropic.com.
@MainActor
protocol OAuthProfileFetching {
    func fetch(credential: Credential) async throws -> OAuthProfileFetcher.Response
}

/// GETs `https://api.anthropic.com/api/oauth/profile` with a CLI OAuth Bearer
/// and returns the small subset of fields Kwota cares about. The response
/// includes `organization.rate_limit_tier` (the only field that carries the
/// "Max 20x" / "Team Premium" suffix today) plus orgUuid and subscription
/// metadata for opportunistic backfill.
///
/// Errors map onto `ClaudeAPIClient.APIError` so the coordinator's recovery
/// paths (401 → forceRefresh, 429 → back off) are uniform with the existing
/// `/api/oauth/usage` consumer.
@MainActor
final class OAuthProfileFetcher: OAuthProfileFetching {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Decoded subset of `/api/oauth/profile`. `planLabel` is resolved in
    /// priority order: `rate_limit_tier` → (`seat_tier` + `organization_type`).
    struct Response: Equatable {
        let planLabel: String?
        let orgUuid: String?
        let subscriptionCreatedAt: Date?
        let subscriptionActive: Bool
        /// Tri-state: nil means the payload omitted `has_extra_usage_enabled`
        /// (or the entire `organization` block). Callers must NOT treat nil
        /// as `false` — see Guard A in `ProfileStore.apply`.
        let hasExtraUsage: Bool?
        let displayName: String?
        let email: String?
        // NEW — Task 2: extended fields surfaced by ProfileDetailView.
        let accountUuid: String?
        let accountCreatedAt: Date?
        let organizationName: String?
        let subscriptionStatus: String?
        let billingType: String?
    }

    static let endpointURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    private let transport: Transport
    private let now: () -> Date

    nonisolated init(
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.now = now
    }

    func fetch(credential: Credential) async throws -> Response {
        // Endpoint requires CLI OAuth Bearer; a cookie sessionKey would 401
        // — short-circuit so callers don't pay a round-trip to learn that.
        guard case .cliToken(let token, _, _) = credential else {
            throw ClaudeAPIClient.APIError.unauthorized
        }
        var req = URLRequest(url: Self.endpointURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(
            "Kwota/0.1 (+https://github.com/thanhhaudev/kwota)",
            forHTTPHeaderField: "User-Agent"
        )
        // Intentionally do NOT set Origin/Referer — this is api.anthropic.com
        // (developer host), not claude.ai. Matches fetchSnapshotViaOAuthUsage.

        let (data, response) = try await transport(req)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeAPIClient.APIError.http(status: -1)
        }
        switch http.statusCode {
        case 200...299:
            return try Self.decode(data)
        case 401, 403:
            throw ClaudeAPIClient.APIError.unauthorized
        case 429:
            throw ClaudeAPIClient.APIError.rateLimited(
                retryAfter: Self.parseRetryAfter(http)
            )
        default:
            throw ClaudeAPIClient.APIError.http(status: http.statusCode)
        }
    }

    // MARK: - decode

    private struct Payload: Decodable {
        let account: Account?
        let organization: Organization?

        struct Account: Decodable {
            let uuid: String?
            let displayName: String?
            let fullName: String?
            let email: String?
            let createdAt: Date?

            enum CodingKeys: String, CodingKey {
                case uuid
                case displayName = "display_name"
                case fullName = "full_name"
                case email
                case createdAt = "created_at"
            }
        }

        struct Organization: Decodable {
            let uuid: String?
            let name: String?
            let rateLimitTier: String?
            let seatTier: String?
            let organizationType: String?
            let subscriptionStatus: String?
            let subscriptionCreatedAt: Date?
            let hasExtraUsageEnabled: Bool?
            let billingType: String?

            enum CodingKeys: String, CodingKey {
                case uuid
                case name
                case rateLimitTier = "rate_limit_tier"
                case seatTier = "seat_tier"
                case organizationType = "organization_type"
                case subscriptionStatus = "subscription_status"
                case subscriptionCreatedAt = "subscription_created_at"
                case hasExtraUsageEnabled = "has_extra_usage_enabled"
                case billingType = "billing_type"
            }
        }
    }

    static func decode(_ data: Data) throws -> Response {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            throw ClaudeAPIClient.APIError.decode("bad ISO8601: \(s)")
        }
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            throw ClaudeAPIClient.APIError.decode(String(describing: error))
        }
        let org = payload.organization
        // Plan resolution: rate_limit_tier wins, then seat_tier (+ orgType).
        let plan = PlanFormatter.format(rateLimitTier: org?.rateLimitTier)
            ?? PlanFormatter.format(seatTier: org?.seatTier, organizationType: org?.organizationType)
        let displayName = payload.account?.fullName?.nonEmpty
            ?? payload.account?.displayName?.nonEmpty
        return Response(
            planLabel: plan,
            orgUuid: org?.uuid,
            subscriptionCreatedAt: org?.subscriptionCreatedAt,
            subscriptionActive: org?.subscriptionStatus == "active",
            hasExtraUsage: org?.hasExtraUsageEnabled,
            displayName: displayName,
            email: payload.account?.email,
            accountUuid: payload.account?.uuid,
            accountCreatedAt: payload.account?.createdAt,
            organizationName: org?.name,
            subscriptionStatus: org?.subscriptionStatus,
            billingType: org?.billingType
        )
    }

    /// Mirror of `ClaudeAPIClient.parseRetryAfter` so the fetcher does not
    /// depend on a private helper there.
    private static func parseRetryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let n = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) { return n }
        return nil
    }
}

private extension String {
    /// `nil` when self is empty after trimming whitespace — keeps the display
    /// name fall-back chain short and obvious.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
