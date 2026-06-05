//
//  ProviderAuthMethodKind.swift
//  Kwota
//

import Foundation

/// Generic across providers. Each provider chooses which kinds it supports
/// (advertised through `AccountProvider.supportedAuthMethods`).
enum ProviderAuthMethodKind: String, Codable, Equatable, CaseIterable, Sendable {
    case cliSync       // local CLI sync (Claude Code, Codex CLI, …)
    case sessionKey    // browser cookie paste / interactive web sign-in
    case apiKey        // user-pasted API key (provider issues long-lived key)
    case webSSO        // embedded WKWebView sign-in flow
}

extension ProviderAuthMethodKind {
    /// Lift a legacy Claude-only `AuthMethodKind` into the broader enum.
    /// Used by `Profile` migration paths and dedup helpers.
    init(legacy: AuthMethodKind) {
        switch legacy {
        case .cliSync: self = .cliSync
        case .sessionKey: self = .sessionKey
        }
    }
}
