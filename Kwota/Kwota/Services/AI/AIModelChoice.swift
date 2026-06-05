//
//  AIModelChoice.swift
//  Kwota
//

import Foundation

/// Claude models the Cache → AI feature can target. The raw value matches
/// the Anthropic model ID so it can be forwarded to `ClaudeAPIClient`
/// (Phase 2) or the `claude --model` CLI flag verbatim.
enum AIModelChoice: String, CaseIterable, Identifiable, Codable {
    case opus47    = "claude-opus-4-7"
    case sonnet46  = "claude-sonnet-4-6"
    case haiku45   = "claude-haiku-4-5-20251001"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus47:   return "Claude Opus 4.7"
        case .sonnet46: return "Claude Sonnet 4.6"
        case .haiku45:  return "Claude Haiku 4.5"
        }
    }

    /// Short hint about latency / cost tradeoff for the Settings picker.
    var caption: String {
        switch self {
        case .opus47:   return "Slowest, deepest reasoning"
        case .sonnet46: return "Balanced speed and depth"
        case .haiku45:  return "Fastest, cheapest — recommended"
        }
    }

    /// Cache-folder classification is a shallow task — Haiku handles it
    /// well and runs ~2× faster than Sonnet through the CLI (measured
    /// ~11s vs ~20s per call). Users who want deeper analysis can switch
    /// to Sonnet/Opus in Settings → Cache.
    static let `default`: AIModelChoice = .haiku45
}
