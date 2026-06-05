//
//  AntigravityAuthMethod.swift
//  Kwota
//

@MainActor
struct AntigravityAuthMethod: ProviderAuthMethod {
    /// Reference to the watcher so `isAvailable` reflects whether the
    /// Antigravity language_server is currently running (cheap to check —
    /// no process spawning at render time).
    let watcher: any AntigravityProcessWatching

    let kind: ProviderAuthMethodKind = .cliSync
    let displayTitle = "Use Antigravity app"
    var displayCaption: String {
        watcher.current != nil
            ? "Detected — open Antigravity and sign in if this is wrong."
            : "Open Antigravity.app and sign in to enable quota tracking."
    }
    let systemImage = "wave.3.right.circle.fill"
    var isAvailable: Bool { watcher.current != nil }
}
