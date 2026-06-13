//
//  AIModelChoice.swift
//  Kwota
//

import Foundation

/// Claude models the Cache → AI feature can target, keyed by family. The
/// raw value is the `claude --model` *alias* (`opus`/`sonnet`/`haiku`),
/// which the CLI resolves to the latest version of that tier — so the
/// picker never goes stale when Anthropic ships a new model. The exact
/// version that actually ran is captured separately for provenance (see
/// `ClaudeCLIRunner` `modelUsage`).
enum AIModelChoice: String, CaseIterable, Identifiable, Codable {
    case opus
    case sonnet
    case haiku

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus:   return "Claude Opus"
        case .sonnet: return "Claude Sonnet"
        case .haiku:  return "Claude Haiku"
        }
    }

    /// Short hint about latency / cost tradeoff for the Settings picker.
    var caption: String {
        switch self {
        case .opus:   return "Slowest, deepest reasoning"
        case .sonnet: return "Balanced speed and depth"
        case .haiku:  return "Fastest, cheapest — recommended"
        }
    }

    /// Cache-folder classification is shallow — Haiku handles it well and
    /// runs fastest/cheapest. Users who want deeper analysis switch tiers
    /// in Settings → Cache.
    static let `default`: AIModelChoice = .haiku

    /// Custom decode so pre-alias `cache-state.json` blobs (which stored
    /// pinned version IDs like `claude-sonnet-4-6`) keep loading, mapped
    /// to the matching family. Unknown raw values fall back to `.default`
    /// rather than failing the whole CachePersistedState decode.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AIModelChoice(rawValue: raw) ?? AIModelChoice.fromLegacyID(raw)
    }

    /// Map a legacy pinned model ID (or anything unrecognized) onto a
    /// family alias. Prefix-based so future `claude-<tier>-*` versions
    /// keep resolving without a code change.
    private static func fromLegacyID(_ raw: String) -> AIModelChoice {
        if raw.hasPrefix("claude-opus") { return .opus }
        if raw.hasPrefix("claude-sonnet") { return .sonnet }
        if raw.hasPrefix("claude-haiku") { return .haiku }
        return .default
    }
}
