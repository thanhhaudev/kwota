//
//  CacheAIEngine.swift
//  Kwota
//

import Foundation

/// Which vendor CLI runs Cache → AI evaluations. Each engine spawns its
/// own CLI headless (`claude -p` / `codex exec` / `agy -p`) and consumes
/// that account's subscription quota — see `ClaudeCLIRunner` /
/// `CodexCLIRunner` / `AntigravityCLIRunner` for why the CLIs are used
/// instead of direct API calls.
enum CacheAIEngine: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude:      return "Claude"
        case .codex:       return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    /// Binary name the engine shells out to. Error copy interpolates this
    /// ("the `claude` command"), so it must stay the literal binary name.
    /// Antigravity's binary is `agy`, not its product name.
    var cliCommand: String {
        switch self {
        case .claude:      return "claude"
        case .codex:       return "codex"
        case .antigravity: return "agy"
        }
    }

    static let `default`: CacheAIEngine = .claude
}
