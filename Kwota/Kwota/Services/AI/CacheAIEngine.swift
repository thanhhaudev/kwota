//
//  CacheAIEngine.swift
//  Kwota
//

import Foundation

/// Which vendor CLI runs Cache → AI evaluations. Each engine spawns its
/// own CLI headless (`claude -p` / `codex exec`) and consumes that
/// account's subscription quota — see `ClaudeCLIRunner` / `CodexCLIRunner`
/// for why the CLIs are used instead of direct API calls.
enum CacheAIEngine: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }

    /// Binary name the engine shells out to. Error copy interpolates this
    /// ("the `claude` command"), so it must stay the literal binary name.
    var cliCommand: String { rawValue }

    static let `default`: CacheAIEngine = .claude
}
