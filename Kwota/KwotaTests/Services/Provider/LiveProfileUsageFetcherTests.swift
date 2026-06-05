//
//  LiveProfileUsageFetcherTests.swift
//  KwotaTests
//
//  Covers the credential-missing and provider-missing failure branches.
//  The success path is exercised end-to-end through ProfileSwitcherCard
//  in higher-level tests; here we only verify the error mapping the
//  coordinator depends on.
//

import XCTest
import SwiftUI
@testable import Kwota

@MainActor
final class LiveProfileUsageFetcherTests: XCTestCase {
    private func claudeProfile(_ email: String) -> Profile {
        Profile(
            id: UUID(),
            name: email,
            authMethod: .cliSync,
            providerID: .claude,
            email: email
        )
    }

    func test_throws_missingCredential_whenKeychainHasNoEntry() async {
        let registry = ProviderRegistry()
        registry.register(StubProvider(id: .claude))
        let store = InMemoryCredentialStore()  // empty
        let profile = claudeProfile("a@x.com")
        let fetcher = LiveProfileUsageFetcher(
            registry: registry,
            credentialStore: store,
            liveIdentityProvider: { [.claude: profile.email] }
        )

        do {
            _ = try await fetcher.fetch(profile: profile)
            XCTFail("expected .missingCredential")
        } catch let ProfileUsageFetcherError.missingCredential(id) {
            XCTAssertNotNil(id)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_throws_missingProvider_whenRegistryHasNoEntry() async {
        let registry = ProviderRegistry()  // no providers
        let store = InMemoryCredentialStore()
        let profile = claudeProfile("a@x.com")
        // .oauth(...) does not exist in this codebase; use .cliToken as a
        // placeholder — its content is irrelevant to the provider-missing branch.
        try? store.write(
            .cliToken(accessToken: "t", refreshToken: "r", expiresAt: Date.distantFuture),
            for: profile.id
        )
        let fetcher = LiveProfileUsageFetcher(
            registry: registry,
            credentialStore: store,
            liveIdentityProvider: { [.claude: profile.email] }
        )

        do {
            _ = try await fetcher.fetch(profile: profile)
            XCTFail("expected .missingProvider")
        } catch ProfileUsageFetcherError.missingProvider(let pid) {
            XCTAssertEqual(pid, .claude)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_throws_cliIdentityMismatch_whenClaudeProfileEmailDoesNotMatchCLI() async {
        let registry = ProviderRegistry()
        registry.register(StubProvider(id: .claude))
        let store = InMemoryCredentialStore()
        let profile = claudeProfile("old@x.com")
        try? store.write(
            .cliToken(accessToken: "t", refreshToken: "r", expiresAt: Date.distantFuture),
            for: profile.id
        )
        let fetcher = LiveProfileUsageFetcher(
            registry: registry,
            credentialStore: store,
            liveIdentityProvider: { [.claude: "new@x.com"] }  // CLI moved to a different account
        )

        do {
            _ = try await fetcher.fetch(profile: profile)
            XCTFail("expected .cliIdentityMismatch")
        } catch ProfileUsageFetcherError.cliIdentityMismatch(let id) {
            XCTAssertEqual(id, profile.id)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_throws_cliIdentityMismatch_whenCodexProfileEmailDoesNotMatchCLI() async {
        let registry = ProviderRegistry()
        registry.register(StubProvider(id: .codex))
        let store = InMemoryCredentialStore()
        let profile = Profile(
            id: UUID(),
            name: "old@x.com",
            authMethod: .cliSync,
            providerID: .codex,
            email: "old@x.com"
        )
        try? store.write(
            .cliToken(accessToken: "t", refreshToken: "r", expiresAt: Date.distantFuture),
            for: profile.id
        )
        let fetcher = LiveProfileUsageFetcher(
            registry: registry,
            credentialStore: store,
            liveIdentityProvider: { [.codex: "new@x.com"] }
        )

        do {
            _ = try await fetcher.fetch(profile: profile)
            XCTFail("expected .cliIdentityMismatch")
        } catch ProfileUsageFetcherError.cliIdentityMismatch(let id) {
            XCTAssertEqual(id, profile.id)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_fetches_whenCLIIdentityMatchesProfileEmail() async throws {
        let registry = ProviderRegistry()
        let stub = StubProvider(id: .claude)
        registry.register(stub)
        let store = InMemoryCredentialStore()
        let profile = claudeProfile("user@x.com")
        try? store.write(
            .cliToken(accessToken: "t", refreshToken: "r", expiresAt: Date.distantFuture),
            for: profile.id
        )
        let fetcher = LiveProfileUsageFetcher(
            registry: registry,
            credentialStore: store,
            liveIdentityProvider: { [.claude: profile.email] }
        )

        let summary = try await fetcher.fetch(profile: profile)
        XCTAssertEqual(summary.providerID, .claude)
        XCTAssertEqual(stub.fetchUsageCallCount, 1)
    }

    func test_antigravity_skipsEmailGuard_andFetchesEvenWhenLiveEmailIsNil() async throws {
        // Antigravity profiles are attributed by the running language_server's
        // CSRF/port (read off the process watcher inside the provider) — not
        // by email. liveIdentityProvider always returns nil for .antigravity,
        // so if the fetcher applied the same email guard it does for Claude
        // and Codex, every switcher refresh would throw cliIdentityMismatch
        // and the row's bars would never render. This guard exemption is
        // load-bearing for the switcher path.
        let registry = ProviderRegistry()
        let stub = StubProvider(id: .antigravity)
        registry.register(stub)
        let store = InMemoryCredentialStore()
        let profile = Profile(
            id: UUID(),
            name: "Antigravity",
            authMethod: .cliSync,
            providerID: .antigravity,
            email: "user@example.com"   // back-filled by provider after first fetch
        )
        try? store.write(
            .cliToken(accessToken: "antigravity-marker", refreshToken: "", expiresAt: .distantFuture),
            for: profile.id
        )
        let fetcher = LiveProfileUsageFetcher(
            registry: registry,
            credentialStore: store,
            liveIdentityProvider: { [.antigravity: nil] }   // realistic: watcher emits no email
        )

        let summary = try await fetcher.fetch(profile: profile)
        XCTAssertEqual(summary.providerID, .antigravity)
        XCTAssertEqual(stub.fetchUsageCallCount, 1)
    }

    func test_antigravity_skipsEmailGuard_evenWhenProfileEmailIsNil() async throws {
        // Pre-backfill scenario: a freshly-created Antigravity profile has no
        // email yet (the provider learns it on first successful fetch). The
        // Claude / Codex branch fails closed in this case; the Antigravity
        // exemption must let the fetch through so the back-fill can happen.
        let registry = ProviderRegistry()
        let stub = StubProvider(id: .antigravity)
        registry.register(stub)
        let store = InMemoryCredentialStore()
        let profile = Profile(
            id: UUID(),
            name: "Antigravity",
            authMethod: .cliSync,
            providerID: .antigravity,
            email: nil
        )
        try? store.write(
            .cliToken(accessToken: "antigravity-marker", refreshToken: "", expiresAt: .distantFuture),
            for: profile.id
        )
        let fetcher = LiveProfileUsageFetcher(
            registry: registry,
            credentialStore: store,
            liveIdentityProvider: { [.antigravity: nil] }
        )

        let summary = try await fetcher.fetch(profile: profile)
        XCTAssertEqual(summary.providerID, .antigravity)
        XCTAssertEqual(stub.fetchUsageCallCount, 1)
    }

    func test_cliIdentityGuard_isCaseInsensitive() async throws {
        // Identity matching across the codebase (ProfileStore.findMatching,
        // AutoProfileCoordinator, isLive picker predicate) uses
        // caseInsensitiveCompare. The guard must follow suit so a CLI that
        // reports "User@Example.com" matches a stored "user@example.com".
        let registry = ProviderRegistry()
        let stub = StubProvider(id: .claude)
        registry.register(stub)
        let store = InMemoryCredentialStore()
        let profile = claudeProfile("user@example.com")
        try? store.write(
            .cliToken(accessToken: "t", refreshToken: "r", expiresAt: Date.distantFuture),
            for: profile.id
        )
        let fetcher = LiveProfileUsageFetcher(
            registry: registry,
            credentialStore: store,
            liveIdentityProvider: { [.claude: "User@Example.com"] }
        )

        let summary = try await fetcher.fetch(profile: profile)
        XCTAssertEqual(summary.providerID, .claude)
        XCTAssertEqual(stub.fetchUsageCallCount, 1)
    }
}

// Lightweight stand-in for KeychainCredentialStore that conforms to the
// same minimal read/write surface the fetcher needs. The production type
// is a concrete final class; we inject through the `CredentialReading`
// protocol defined in ProfileUsageFetcher.swift.
@MainActor
private final class InMemoryCredentialStore: CredentialReading {
    private var store: [UUID: Credential] = [:]
    func read(for id: UUID) throws -> Credential? { store[id] }
    func write(_ credential: Credential, for id: UUID) throws { store[id] = credential }
}

@MainActor
private final class StubProvider: AccountProvider {
    let id: ProviderID
    let displayName: String = "Stub"
    let iconAssetName: String = "Mascot"
    let supportedAuthMethods: [any ProviderAuthMethod] = []
    private(set) var fetchUsageCallCount = 0
    init(id: ProviderID) { self.id = id }
    func fetchUsage(credential: Credential, profile: Profile) async throws -> ProviderUsageSummary {
        fetchUsageCallCount += 1
        return ProviderUsageSummary(
            providerID: id, fetchedAt: Date(),
            primary: nil, secondary: nil,
            payload: UsageSnapshot.zeroes()
        )
    }
    func usageDetailView(summary: ProviderUsageSummary, history: [UsageHistoryEntry], profile: Profile) -> AnyView { AnyView(EmptyView()) }
    func planBadgeView(profile: Profile) -> AnyView { AnyView(EmptyView()) }
}
