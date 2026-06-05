//
//  ProfileUsageFetcher.swift
//  Kwota
//
//  Seam around "fetch a fresh ProviderUsageSummary for any profile".
//  ProfileSwitcherCard uses this to lazy-load per-row utilization on
//  expand without re-reaching into the view-model's active-profile-only
//  refresh path. The live impl resolves the credential through
//  KeychainCredentialStore and the provider through ProviderRegistry;
//  tests inject mocks that conform to the same protocol.
//
//  Identity guard: ClaudeProvider.fetchUsage routes through
//  CLITokenRefresher, which reads / writes the *current* CLI account's
//  tokens. Without a guard, a row fetch for a profile whose email no
//  longer matches the live CLI account could pull the new account's
//  usage AND overwrite the old profile's stored credential with the
//  new token. We refuse to fetch unless `liveIdentityProvider` reports
//  an email that matches `profile.email` (case-insensitive) for the
//  profile's provider. The picker's `isLive` filter is an upstream
//  defense; this is the defense-in-depth fence inside the fetcher.
//

import Foundation

/// Minimal credential-store surface the fetcher consumes. The full
/// KeychainCredentialStore type already provides this shape — we just
/// declare a protocol so tests can inject an in-memory variant.
@MainActor
protocol CredentialReading: AnyObject {
    func read(for id: UUID) throws -> Credential?
}

extension KeychainCredentialStore: CredentialReading {}

@MainActor
protocol ProfileUsageFetching: AnyObject {
    func fetch(profile: Profile) async throws -> ProviderUsageSummary
}

/// Snapshot of "what email is each provider's CLI currently signed in as?"
/// Returned by a closure so the fetcher reads it fresh on every fetch
/// rather than caching at construction.
typealias LiveIdentityProvider = @MainActor () -> [ProviderID: String?]

enum ProfileUsageFetcherError: Error, Equatable {
    /// Profile exists but the keychain has no credential for it. Usually
    /// means the user revoked the CLI session since the profile was added;
    /// the row should render an error state and stay clickable to switch.
    case missingCredential(profileID: UUID)

    /// Profile's `providerID` is not registered in the live registry —
    /// e.g. a provider whose plugin was disabled at runtime. The row drops
    /// to an error state.
    case missingProvider(ProviderID)

    /// Profile's email no longer matches the live CLI account for its
    /// provider. Fetching anyway risks attributing the new account's
    /// usage to the old profile and (for Claude) silently overwriting
    /// the stored credential with the live CLI token. We fail closed.
    case cliIdentityMismatch(profileID: UUID)
}

@MainActor
final class LiveProfileUsageFetcher: ProfileUsageFetching {
    private let registry: ProviderRegistry
    private let credentialStore: any CredentialReading
    private let liveIdentityProvider: LiveIdentityProvider

    init(
        registry: ProviderRegistry,
        credentialStore: any CredentialReading,
        liveIdentityProvider: @escaping LiveIdentityProvider
    ) {
        self.registry = registry
        self.credentialStore = credentialStore
        self.liveIdentityProvider = liveIdentityProvider
    }

    func fetch(profile: Profile) async throws -> ProviderUsageSummary {
        guard let credential = try credentialStore.read(for: profile.id) else {
            throw ProfileUsageFetcherError.missingCredential(profileID: profile.id)
        }
        guard let provider = registry.provider(for: profile.providerID) else {
            throw ProfileUsageFetcherError.missingProvider(profile.providerID)
        }
        // Antigravity exemption: identity is attributed by the running
        // language_server's CSRF/port (read off the watcher inside
        // AntigravityProvider.fetchUsage), not by email. The watcher emits
        // no email, so liveIdentityProvider always returns nil for this
        // provider and the email-comparison check below would always fail,
        // even though the profile is perfectly valid. Defer the liveness
        // check to the provider's own IdentityMismatchError throw.
        //
        // Without this exemption the switcher row goes through this fetcher
        // and fails cliIdentityMismatch on every refresh, evicting the
        // cached summary and leaving the row's bars empty — observable in
        // production as "Pmt / Flw bars never render".
        if profile.providerID != .antigravity {
            // Identity guard — case-insensitive on email, consistent with
            // ProfileStore.findMatching, AutoProfileCoordinator, and the
            // ProfileSwitcherCard.isLive predicate.
            let liveEmails = liveIdentityProvider()
            let liveEmail = liveEmails[profile.providerID] ?? nil
            if let profileEmail = profile.email,
               liveEmail?.caseInsensitiveCompare(profileEmail) != .orderedSame {
                throw ProfileUsageFetcherError.cliIdentityMismatch(profileID: profile.id)
            }
            if profile.email == nil {
                // Profile with no email cannot be matched against the live CLI.
                // Fail closed rather than silently passing.
                throw ProfileUsageFetcherError.cliIdentityMismatch(profileID: profile.id)
            }
        }
        return try await provider.fetchUsage(credential: credential, profile: profile)
    }
}
