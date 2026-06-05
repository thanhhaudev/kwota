//
//  ProviderUsageSummary.swift
//  Kwota
//

import Foundation

/// Provider-agnostic usage shape consumed by chrome views (header card,
/// expiry banner, refresh button). The provider-specific payload (e.g.
/// `UsageSnapshot` for Claude) is opaque here and only re-typed inside the
/// provider's own detail view.
struct ProviderUsageSummary {
    let providerID: ProviderID
    let fetchedAt: Date
    /// Headline utilization bucket (e.g. Claude's 5h session). The shell
    /// uses this for the menu-bar badge / banner; provider-specific charts
    /// continue to read the full payload.
    let primary: UsageBucket?
    /// Secondary bucket (e.g. Claude's 7-day rolling window).
    let secondary: UsageBucket?
    /// Provider-specific full snapshot. Cast back inside the provider's
    /// `usageDetailView`.
    let payload: any Sendable
    /// Server-suggested back-off in seconds (parsed from a 429 with usable
    /// headers). Shell pushes the next refresh tick out by this much.
    let retryAfter: TimeInterval?

    init(
        providerID: ProviderID,
        fetchedAt: Date,
        primary: UsageBucket?,
        secondary: UsageBucket?,
        payload: any Sendable,
        retryAfter: TimeInterval? = nil
    ) {
        self.providerID = providerID
        self.fetchedAt = fetchedAt
        self.primary = primary
        self.secondary = secondary
        self.payload = payload
        self.retryAfter = retryAfter
    }

    /// True when at least one headline bucket carries a real utilization
    /// value. A summary where both are absent renders as two empty bars —
    /// e.g. Codex's `wham/usage` intermittently returns `rate_limit: null`
    /// on an HTTP 200, which decodes to a valid-but-empty summary. Such a
    /// degraded result must not be allowed to overwrite a cached summary
    /// that still has data; callers gate retention on this. Note the check
    /// is on `utilization`, not bucket presence: a bucket can exist with a
    /// nil utilization and still be empty.
    var hasBucketData: Bool {
        primary?.utilization != nil || secondary?.utilization != nil
    }

    /// Decides whether a freshly-fetched `incoming` summary should be
    /// discarded in favor of `previous`. Returns `true` only when the fetch
    /// succeeded but came back empty (no bucket data) while `previous` —
    /// the last good summary for the *same* provider — still has data. This
    /// is the degraded-but-successful case (Codex's `rate_limit: null` on a
    /// 200): treating it as a transient hiccup keeps the bars and badge from
    /// blanking. The same-provider guard stops a just-switched profile's
    /// empty first fetch from being masked by the prior provider's data.
    /// Shared by the switcher coordinator and the active refresh path so
    /// both surfaces apply identical retention.
    static func shouldRetain(
        previous: ProviderUsageSummary?,
        over incoming: ProviderUsageSummary
    ) -> Bool {
        guard !incoming.hasBucketData,
              let previous,
              previous.providerID == incoming.providerID,
              previous.hasBucketData
        else { return false }
        return true
    }
}
