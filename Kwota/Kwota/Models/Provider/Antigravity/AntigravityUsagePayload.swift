//
//  AntigravityUsagePayload.swift
//  Kwota
//
//  Composite payload shipped on ProviderUsageSummary for Antigravity. Carries
//  the GetUserStatus snapshot (identity/plan/AI-credits wallet) plus the
//  authoritative RetrieveUserQuotaSummary (per-group weekly/5h). `quota` is
//  optional so a quota-fetch miss degrades to "quota unavailable" without
//  losing identity/plan rendering.
//

import Foundation

struct AntigravityUsagePayload: Sendable, Equatable {
    let snapshot: AntigravityUsageSnapshot
    let quota: AntigravityQuotaSummary?
}
