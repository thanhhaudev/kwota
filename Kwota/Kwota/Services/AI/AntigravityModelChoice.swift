//
//  AntigravityModelChoice.swift
//  Kwota
//

import Foundation

/// Models the Cache → AI feature can target when the Antigravity engine is
/// selected. `agy` 1.0.8 exposes `--model`; this is a curated Gemini subset
/// of `agy models` (the non-Gemini entries — Claude/Opus/GPT-OSS — overlap
/// the dedicated Claude/Codex engines, so they're left out).
///
/// `rawValue` is a stable persisted slug. `cliModelArg` is the EXACT display
/// string `agy models` prints — agy may silently ignore an unrecognized
/// `--model`, so the value must come from its own list verbatim. agy `-p`
/// doesn't echo the resolved model, so provenance is request-based.
enum AntigravityModelChoice: String, CaseIterable, Identifiable, Codable {
    case agyDefault        = "default"
    case gemini35FlashLow  = "gemini-3.5-flash-low"
    case gemini35FlashMedium = "gemini-3.5-flash-medium"
    case gemini35FlashHigh = "gemini-3.5-flash-high"
    case gemini31ProLow    = "gemini-3.1-pro-low"
    case gemini31ProHigh   = "gemini-3.1-pro-high"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .agyDefault:          return "Antigravity default"
        case .gemini35FlashLow:    return "Gemini 3.5 Flash (Low)"
        case .gemini35FlashMedium: return "Gemini 3.5 Flash (Medium)"
        case .gemini35FlashHigh:   return "Gemini 3.5 Flash (High)"
        case .gemini31ProLow:      return "Gemini 3.1 Pro (Low)"
        case .gemini31ProHigh:     return "Gemini 3.1 Pro (High)"
        }
    }

    /// Short hint for the Settings picker, mirroring the other model enums.
    var caption: String {
        switch self {
        case .agyDefault:          return "Uses your Antigravity CLI's configured model — recommended"
        case .gemini35FlashLow:    return "Fastest, cheapest"
        case .gemini35FlashMedium: return "Balanced speed and depth"
        case .gemini35FlashHigh:   return "Flash with deeper reasoning"
        case .gemini31ProLow:      return "Pro model, lighter reasoning"
        case .gemini31ProHigh:     return "Slowest, deepest reasoning"
        }
    }

    /// Value for `agy --model` — the exact `agy models` display string; nil
    /// omits the flag so agy uses its configured default.
    var cliModelArg: String? {
        switch self {
        case .agyDefault:          return nil
        case .gemini35FlashLow:    return "Gemini 3.5 Flash (Low)"
        case .gemini35FlashMedium: return "Gemini 3.5 Flash (Medium)"
        case .gemini35FlashHigh:   return "Gemini 3.5 Flash (High)"
        case .gemini31ProLow:      return "Gemini 3.1 Pro (Low)"
        case .gemini31ProHigh:     return "Gemini 3.1 Pro (High)"
        }
    }

    /// String stamped into `CacheAIEvaluation.modelUsed`. agy `-p` doesn't
    /// echo the resolved model, so for an explicit pick this is the
    /// requested model; for default it's a stable placeholder.
    var provenanceLabel: String {
        self == .agyDefault ? "antigravity-default" : (cliModelArg ?? "antigravity-default")
    }

    static let `default`: AntigravityModelChoice = .agyDefault
}
