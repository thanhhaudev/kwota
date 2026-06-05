//
//  ProviderAuthMethod.swift
//  Kwota
//

/// One way to add a credential to a provider. Each provider exposes 1+ methods
/// (e.g. Claude has CLI / web SSO / paste session-key).
@MainActor
protocol ProviderAuthMethod {
    var kind: ProviderAuthMethodKind { get }
    var displayTitle: String { get }
    var displayCaption: String { get }
    var systemImage: String { get }
    /// Returns `false` when prerequisites are missing (e.g. Claude CLI not
    /// installed). The Add Profile wizard greys the row out.
    var isAvailable: Bool { get }
}

extension AuthMethodKind {
    /// Project the broader `ProviderAuthMethodKind` onto the legacy
    /// Claude-only `AuthMethodKind`. Non-Claude method kinds (`apiKey`,
    /// `webSSO`) collapse to `.sessionKey` for now — they're stored as
    /// opaque `Credential.sessionKey` blobs anyway. When `AuthMethodKind`
    /// is replaced wholesale in a follow-up, this helper goes away.
    init(_ kind: ProviderAuthMethodKind) {
        switch kind {
        case .cliSync: self = .cliSync
        case .sessionKey, .apiKey, .webSSO: self = .sessionKey
        }
    }
}
