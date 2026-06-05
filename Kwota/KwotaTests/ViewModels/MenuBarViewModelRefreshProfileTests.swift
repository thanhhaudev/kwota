//
//  MenuBarViewModelRefreshProfileTests.swift
//  KwotaTests

import XCTest
import SwiftUI
@testable import Kwota

@MainActor
final class MenuBarViewModelRefreshProfileTests: XCTestCase {
    private var temp: TempDirectory!
    private var keychain: KeychainCredentialStore!
    private var profileStore: ProfileStore!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
        let service = "com.thanhhaudev.Kwota.test.\(UUID())"
        keychain = KeychainCredentialStore(service: service)
        let dataRoot = temp.url
        profileStore = ProfileStore(
            profilesFile: temp.file("profiles.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in dataRoot.appendingPathComponent(id.uuidString) }
        )
    }

    override func tearDown() async throws {
        try? keychain.deleteAll()
        try await super.tearDown()
    }

    private func makeVM(stubFetcher: StubOAuthProfileFetcher, registry: ProviderRegistry? = nil) -> MenuBarViewModel {
        let codexWatcherStub = CodexAccountWatcher(
            authRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let codexCoordStub = CodexAutoProfileCoordinator(
            watcher: codexWatcherStub,
            profileStore: profileStore,
            keychain: keychain,
            clock: { Date() }
        )
        // Hermetic UsageMonitor: prevents the live default from reading
        // ~/.claude/projects/**/*.jsonl and writing to the shared ledger
        // during parallel test runs.
        let usage = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: temp.file("ledger-\(UUID().uuidString).json"),
            dailyCounterURL: temp.file("daily-counter-\(UUID().uuidString).json")
        )
        return MenuBarViewModel(
            usage: usage,
            profileStore: profileStore,
            credentialStore: keychain,
            registry: registry,
            activitySource: CompositeActivitySource(sources: []),
            codexAccountWatcher: codexWatcherStub,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            oauthProfileFetcher: stubFetcher,
            codexAutoProfileCoordinator: codexCoordStub
        )
    }

    private func seedProfile(plan: String? = "Max", status: String? = nil) throws -> Profile {
        let p = Profile(
            name: "Hau", authMethod: .cliSync,
            subscriptionPlan: plan,
            email: "h@x.com",
            subscriptionStatus: status
        )
        try profileStore.add(p)
        try keychain.write(.cliToken(accessToken: "T", refreshToken: "r",
                                     expiresAt: .distantFuture), for: p.id)
        return p
    }

    private func makeResponse(
        planLabel: String? = "Max 20x",
        subscriptionStatus: String? = "active"
    ) -> OAuthProfileFetcher.Response {
        OAuthProfileFetcher.Response(
            planLabel: planLabel, orgUuid: "org-1", subscriptionCreatedAt: nil,
            subscriptionActive: subscriptionStatus == "active",
            hasExtraUsage: false, displayName: nil, email: nil,
            accountUuid: nil, accountCreatedAt: nil, organizationName: nil,
            subscriptionStatus: subscriptionStatus, billingType: nil
        )
    }

    // MARK: - Cases

    func test_refreshProfileMetadata_returnsUpdated_whenFieldsChange() async throws {
        let p = try seedProfile(plan: "Max")
        let stub = StubOAuthProfileFetcher()
        stub.outcome = .success(makeResponse(planLabel: "Max 20x"))
        let vm = makeVM(stubFetcher: stub)

        let result = await vm.refreshProfileMetadata(for: p.id)
        XCTAssertEqual(result, .updated)
        let stored = profileStore.profiles.first(where: { $0.id == p.id })!
        XCTAssertEqual(stored.subscriptionPlan, "Max 20x")
    }

    func test_refreshProfileMetadata_returnsNoChange_whenAllFieldsMatch() async throws {
        // Seed a profile whose persisted fields exactly match what the response
        // will return, including hasExtraUsageEnabled (nil vs false diverges)
        // and organizationId (response carries orgUuid: "org-1").
        var p = try seedProfile(plan: "Max 20x", status: "active")
        // Patch hasExtraUsageEnabled and organizationId so apply() sees no diff.
        p.hasExtraUsageEnabled = false
        p.organizationId = "org-1"
        try profileStore.updateProfile(p)
        let stub = StubOAuthProfileFetcher()
        stub.outcome = .success(makeResponse(planLabel: "Max 20x", subscriptionStatus: "active"))
        let vm = makeVM(stubFetcher: stub)

        let result = await vm.refreshProfileMetadata(for: p.id)
        XCTAssertEqual(result, .noChange)
    }

    func test_refreshProfileMetadata_returnsUnauthorized_on401() async throws {
        let p = try seedProfile()
        let stub = StubOAuthProfileFetcher()
        stub.outcome = .failure(ClaudeAPIClient.APIError.unauthorized)
        let vm = makeVM(stubFetcher: stub)

        let result = await vm.refreshProfileMetadata(for: p.id)
        XCTAssertEqual(result, .unauthorized)
    }

    func test_refreshProfileMetadata_returnsRateLimited_withRetryAfter() async throws {
        let p = try seedProfile()
        let stub = StubOAuthProfileFetcher()
        stub.outcome = .failure(ClaudeAPIClient.APIError.rateLimited(retryAfter: 42))
        let vm = makeVM(stubFetcher: stub)

        let result = await vm.refreshProfileMetadata(for: p.id)
        XCTAssertEqual(result, .rateLimited(retryAfter: 42))
    }

    func test_refreshProfileMetadata_returnsOffline_onURLErrorNotConnected() async throws {
        let p = try seedProfile()
        let stub = StubOAuthProfileFetcher()
        stub.outcome = .failure(URLError(.notConnectedToInternet))
        let vm = makeVM(stubFetcher: stub)

        let result = await vm.refreshProfileMetadata(for: p.id)
        XCTAssertEqual(result, .offline)
    }

    func test_refreshProfileMetadata_returnsOtherError_onUnknownThrow() async throws {
        let p = try seedProfile()
        let stub = StubOAuthProfileFetcher()
        let oddError = NSError(domain: "Test", code: 99, userInfo: [NSLocalizedDescriptionKey: "boom"])
        stub.outcome = .failure(oddError)
        let vm = makeVM(stubFetcher: stub)

        let result = await vm.refreshProfileMetadata(for: p.id)
        XCTAssertEqual(result, .otherError("boom"))
    }

    func test_refreshProfileMetadata_returnsOtherError_whenKeychainHasNoCredential() async throws {
        let p = Profile(name: "Hau", authMethod: .cliSync, email: "h@x.com")
        try profileStore.add(p)
        // Intentionally do NOT seed keychain.
        let stub = StubOAuthProfileFetcher()
        let vm = makeVM(stubFetcher: stub)

        let result = await vm.refreshProfileMetadata(for: p.id)
        if case .otherError = result {
            // ok — accept any otherError message
        } else {
            XCTFail("expected .otherError, got \(result)")
        }
        XCTAssertEqual(stub.callCount, 0, "fetcher must NOT be called when keychain miss")
    }

    // MARK: - Provider-agnostic dispatch

    /// Proves the shell routes through the registry (no `if claude`): a
    /// non-Claude profile reaches its provider's `refreshProfileMetadata`,
    /// and every `ProviderMetadataRefreshError` maps to the right
    /// `RefreshResult`.
    func test_refreshProfileMetadata_dispatchesToProviderAndMapsErrors() async throws {
        let cases: [(StubRefreshProvider.Outcome, MenuBarViewModel.RefreshResult)] = [
            (.changed,                                    .updated),
            (.unchanged,                                  .noChange),
            (.fail(.unauthorized),                        .unauthorized),
            (.fail(.rateLimited(retryAfter: 7)),          .rateLimited(retryAfter: 7)),
            (.fail(.offline),                             .offline),
            (.fail(.identityMismatch(message: "nope")),   .otherError("nope")),
            (.fail(.other(message: "boom")),              .otherError("boom"))
        ]
        for (outcome, expected) in cases {
            let p = Profile(name: "Gx", authMethod: .cliSync,
                            providerID: .codex, email: "g@x.com")
            try profileStore.add(p)
            try keychain.write(.cliToken(accessToken: "T", refreshToken: "r",
                                         expiresAt: .distantFuture), for: p.id)
            let stub = StubRefreshProvider(id: .codex, outcome: outcome)
            let registry = ProviderRegistry()
            registry.register(stub)
            let vm = makeVM(stubFetcher: StubOAuthProfileFetcher(), registry: registry)

            let result = await vm.refreshProfileMetadata(for: p.id)
            XCTAssertEqual(result, expected, "outcome \(outcome)")
            try? profileStore.remove(id: p.id)
        }
    }

    func test_refreshProfileMetadata_returnsOtherError_onIdentityMismatch() async throws {
        // Profile bound to org-A; probe returns org-B → apply throws
        // identityMismatch → VM surfaces a clear user-visible banner.
        let p = Profile(
            name: "Hau", authMethod: .cliSync,
            organizationId: "org-A",
            email: "h@x.com"
        )
        try profileStore.add(p)
        try keychain.write(.cliToken(accessToken: "T", refreshToken: "r",
                                     expiresAt: .distantFuture), for: p.id)

        let stub = StubOAuthProfileFetcher()
        stub.outcome = .success(OAuthProfileFetcher.Response(
            planLabel: "Team", orgUuid: "org-B", subscriptionCreatedAt: nil,
            subscriptionActive: true, hasExtraUsage: nil,
            displayName: nil, email: nil,
            accountUuid: nil, accountCreatedAt: nil, organizationName: nil,
            subscriptionStatus: "active", billingType: nil
        ))
        let vm = makeVM(stubFetcher: stub)

        let result = await vm.refreshProfileMetadata(for: p.id)
        if case .otherError(let msg) = result {
            XCTAssertTrue(msg.contains("different account"),
                          "expected user-readable identity-mismatch message, got: \(msg)")
        } else {
            XCTFail("expected .otherError, got \(result)")
        }
        // Stored fields must be unchanged.
        let stored = profileStore.profiles.first(where: { $0.id == p.id })!
        XCTAssertEqual(stored.organizationId, "org-A")
        XCTAssertNil(stored.subscriptionPlan)
    }
}

/// Minimal AccountProvider whose `refreshProfileMetadata` returns a fixed
/// outcome — lets the dispatch test prove the shell is provider-agnostic
/// without standing up a real provider. All other members are inert.
@MainActor
private final class StubRefreshProvider: AccountProvider {
    enum Outcome {
        case changed
        case unchanged
        case fail(ProviderMetadataRefreshError)
    }
    let id: ProviderID
    let displayName = "Stub"
    let iconAssetName = "Mascot"
    let outcome: Outcome

    init(id: ProviderID, outcome: Outcome) {
        self.id = id
        self.outcome = outcome
    }

    var supportedAuthMethods: [any ProviderAuthMethod] { [] }

    func fetchUsage(credential: Credential, profile: Profile) async throws -> ProviderUsageSummary {
        throw ProviderMetadataRefreshError.other(message: "unused")
    }

    func refreshProfileMetadata(for profile: Profile, credential: Credential) async throws -> Bool {
        switch outcome {
        case .changed:        return true
        case .unchanged:      return false
        case .fail(let err):  throw err
        }
    }

    func usageDetailView(summary: ProviderUsageSummary,
                         history: [UsageHistoryEntry],
                         profile: Profile) -> AnyView { AnyView(EmptyView()) }
    func planBadgeView(profile: Profile) -> AnyView { AnyView(EmptyView()) }
}

// Local copy of StubOAuthProfileFetcher (the one in AutoProfileCoordinatorTests
// is fileprivate). Kept minimal: configurable outcome + call counter.
@MainActor
private final class StubOAuthProfileFetcher: OAuthProfileFetching {
    enum Outcome {
        case success(OAuthProfileFetcher.Response)
        case failure(Error)
    }
    var outcome: Outcome = .success(.init(
        planLabel: nil, orgUuid: nil, subscriptionCreatedAt: nil,
        subscriptionActive: false, hasExtraUsage: false,
        displayName: nil, email: nil,
        accountUuid: nil, accountCreatedAt: nil, organizationName: nil,
        subscriptionStatus: nil, billingType: nil
    ))
    private(set) var callCount = 0

    func fetch(credential: Credential) async throws -> OAuthProfileFetcher.Response {
        callCount += 1
        switch outcome {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}
