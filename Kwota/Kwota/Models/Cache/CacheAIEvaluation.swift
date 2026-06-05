//
//  CacheAIEvaluation.swift
//  Kwota
//

import Foundation

/// LLM-produced assessment for a single tracked cache path. Persists across
/// app launches so the same path doesn't burn a round-trip every time the
/// popover opens — the user explicitly triggers a re-evaluation when they
/// want fresh judgement.
struct CacheAIEvaluation: Codable, Equatable {
    enum Safety: String, Codable, Equatable {
        case safe       // delete freely — content rebuilds or is non-critical
        case caution    // delete OK with caveats (re-downloads, lost session state)
        case risky      // user-owned data or active state — avoid auto-clean
        case unknown    // LLM couldn't determine
    }

    /// LLM verdict. Drives the inline annotation color and may override the
    /// hand-curated `risk` on `CachePathRow` once evaluation completes.
    let safety: Safety

    /// Short caveat shown inline under the path. nil when the path is
    /// unambiguously safe and needs no qualifier.
    let warning: String?

    /// "What is this folder used for" in plain language. Always present —
    /// the primary value of the AI feature for users who don't recognize
    /// `com.apple.iconservices.store`.
    let purpose: String

    /// Longer explanation for the detail sheet. nil when the short
    /// `purpose` is sufficient.
    let detail: String?

    /// Model ID that produced this evaluation (e.g., "claude-sonnet-4-6").
    /// Stored so the detail sheet can show provenance and a future
    /// invalidation pass can clear evals from deprecated models.
    let modelUsed: String

    /// Wall-clock time at evaluation. Drives the "last evaluated X ago"
    /// hint and a future TTL-based invalidation if we add one.
    let evaluatedAt: Date
}
