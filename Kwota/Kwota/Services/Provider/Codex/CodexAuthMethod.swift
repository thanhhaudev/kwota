//
//  CodexAuthMethod.swift
//  Kwota
//

@MainActor
struct CodexAuthMethod: ProviderAuthMethod {
    let reader: CodexAuthReader

    let kind: ProviderAuthMethodKind = .cliSync
    let displayTitle = "Use Codex CLI"
    var displayCaption: String {
        reader.read() != nil
            ? "Detected — sign in with `codex login` if this is wrong."
            : "No Codex credentials — run `codex login` first."
    }
    let systemImage = "terminal.fill"
    var isAvailable: Bool { reader.read() != nil }
}
