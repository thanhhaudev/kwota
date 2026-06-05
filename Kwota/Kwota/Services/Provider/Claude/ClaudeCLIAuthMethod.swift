//
//  ClaudeCLIAuthMethod.swift
//  Kwota
//

@MainActor
struct ClaudeCLIAuthMethod: ProviderAuthMethod {
    let reader: CLICredentialReader
    let accountReader: OAuthAccountReader

    let kind: ProviderAuthMethodKind = .cliSync
    let displayTitle = "Use Claude Code CLI"
    // `reader.isAvailable` is now file-only (no Keychain probe), so reading it
    // here for the caption never triggers a consent prompt.
    var displayCaption: String {
        reader.isAvailable
            ? "Detected — sign in with `claude login` if this is wrong."
            : "No Claude Code credentials — run `claude login` first."
    }
    let systemImage = "terminal.fill"
    var isAvailable: Bool { reader.isAvailable }
}
