//
//  CodexModelChoice.swift
//  Kwota
//

import Foundation

/// Models the Cache → AI feature can target when the Codex engine is
/// selected. Raw values (except `codexDefault`) are OpenAI model slugs
/// forwarded verbatim to `codex exec -m`.
///
/// `codexDefault` omits `-m` entirely so codex resolves the model from
/// the user's `~/.codex/config.toml` — immune to OpenAI model renames
/// (the CLI ships a `notice.model_migrations` table because churn is
/// real). Slugs verified against `~/.codex/models_cache.json`, 2026-06.
enum CodexModelChoice: String, CaseIterable, Identifiable, Codable {
    case codexDefault = "default"
    case gpt55        = "gpt-5.5"
    case gpt54        = "gpt-5.4"
    case gpt54Mini    = "gpt-5.4-mini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codexDefault: return "Codex default"
        case .gpt55:        return "GPT-5.5"
        case .gpt54:        return "GPT-5.4"
        case .gpt54Mini:    return "GPT-5.4 Mini"
        }
    }

    /// Short hint for the Settings picker, mirroring `AIModelChoice.caption`.
    var caption: String {
        switch self {
        case .codexDefault: return "Uses your Codex CLI's configured model — recommended"
        case .gpt55:        return "Slowest, deepest reasoning"
        case .gpt54:        return "Balanced speed and depth"
        case .gpt54Mini:    return "Fastest, cheapest"
        }
    }

    /// Value for `codex exec -m`; nil omits the flag so the CLI falls
    /// back to the user's configured default model.
    var cliModelArg: String? {
        self == .codexDefault ? nil : rawValue
    }

    /// String stamped into `CacheAIEvaluation.modelUsed`. The resolved
    /// model behind `codexDefault` isn't known without parsing the CLI's
    /// event stream, so it stamps a stable placeholder instead.
    var provenanceLabel: String {
        self == .codexDefault ? "codex-default" : rawValue
    }

    static let `default`: CodexModelChoice = .codexDefault
}
