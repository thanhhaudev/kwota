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
        // Full hermetic kit (mirrors MenuBarViewModelActivityForwardingTests):
        // seedProfile() runs BEFORE makeVM and ProfileStore.add activates the
        // profile, so the init-driven refresh tick fires immediately. Every
        // default that could reach the network (ClaudeAPIClient.live() inside
        // the default registry, 401-retry posting the fake refresh token to
        // the real OAuth endpoint), the real ~/.claude.json, or Claude Code's
        // Keychain item must be stubbed out.
        let vmWatcher = CLIAccountWatcher(
            oauthRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let coordWatcher = CLIAccountWatcher(
            oauthRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let permissiveCoord = AutoProfileCoordinator(
            watcher: coordWatcher,
            profileStore: profileStore,
            alwaysAllowRefresh: true
        )
        let codexWatcherStub = CodexAccountWatcher(
            authRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let codexCoordWatcher = CodexAccountWatcher(
            authRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let codexCoordStub = CodexAutoProfileCoordinator(
            watcher: codexCoordWatcher,
            profileStore: profileStore,
            keychain: keychain,
            clock: { Date() }
        )
        let antigravityWatcherVM = AntigravityProcessWatcher(detect: { nil })
        let antigravityWatcherCoord = AntigravityProcessWatcher(detect: { nil })
        let antigravityCoordStub = AntigravityAutoProfileCoordinator(
            watcher: antigravityWatcherCoord,
            profileStore: profileStore
        )
        let sandboxedDefaults = UserDefaults(suiteName: "kwota-refresh-profile-test-\(UUID())")!
        sandboxedDefaults.set(true, forKey: "autoDetectMigrationCompleted")
        let inertMigrator = AutoProfileMigrator(
            profileStore: profileStore,
            oauthRead: { nil },
            defaults: sandboxedDefaults
        )
        // Hermetic UsageMonitor: prevents the live default from reading
        // ~/.claude/projects/**/*.jsonl and writing to the shared ledger
        // during parallel test runs.
        let usage = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: temp.file("ledger-\(UUID().uuidString).json"),
            dailyCounterURL: temp.file("daily-counter-\(UUID().uuidString).json")
        )
        let stubClient = ClaudeAPIClient(transport: { req in
            let url = req.url ?? URL(string: "https://example.invalid")!
            let resp = HTTPURLResponse(url: url, statusCode: 401,
                                       httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        })
        // Stub refresher: reader points at a missing temp file with a nil
        // keychain probe so forceRefresh never touches Claude Code's real
        // Keychain item or ~/.claude/.credentials.json.
        let stubRefresher = CLITokenRefresher(
            reader: CLICredentialReader(
                credentialsFile: temp.file("missing-credentials.json"),
                keychainProbe: { nil }
            ),
            store: keychain
        )
        let tempDir = temp!
        return MenuBarViewModel(
            usage: usage,
            statsStore: makeHermeticStatsStore(),
            cachePersistence: CachePersistenceStore(url: temp.file("cache-state-\(UUID().uuidString).json")),
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: stubClient,
            cliRefresher: stubRefresher,
            registry: registry,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: vmWatcher,
            codexAccountWatcher: codexWatcherStub,
            antigravityProcessWatcher: antigravityWatcherVM,
            oauthProfileFetcher: stubFetcher,
            autoProfileCoordinator: permissiveCoord,
            codexAutoProfileCoordinator: codexCoordStub,
            antigravityAutoProfileCoordinator: antigravityCoordStub,
            autoProfileMigrator: inertMigrator,
            activityHistorian: ActivityHistorian(autoBackfill: false),
            historyFileProvider: { id in tempDir.file("history-\(id.uuidString).json") }
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
            XCTAssertTrue(msg.contains("different Claude"),
                          "expected user-readable identity-mismatch message, got: \(msg)")
        } else {
            XCTFail("expected .otherError, got \(result)")
        }
        // Stored fields must be unchanged.
        let stored = profileStore.profiles.first(where: { $0.id == p.id })!
        XCTAssertEqual(stored.organizationId, "org-A")
        XCTAssertNil(stored.subscriptionPlan)
    }

    // MARK: - Manual Refresh re-probes plan metadata

    /// A manual popover Refresh self-heals a stale plan badge: when the usage
    /// fetch leaves the provider healthy AND the provider keeps its plan
    /// behind a separate endpoint (Claude), the shell fires the post-usage
    /// metadata probe. Proven via the probe call count.
    ///
    /// (`fetchError: .offline` is benign — it routes to the generic catch, so
    /// authState stays `.authenticated` and no rate-limit is armed; the probe
    /// is gated on health, not on the usage fetch returning data.)
    func test_manualRefresh_separatePlanProvider_probesWhenHealthy() async throws {
        let p = Profile(name: "Hau", authMethod: .cliSync,
                        providerID: .claude, email: "h@x.com")
        try profileStore.add(p)
        try keychain.write(.cliToken(accessToken: "T", refreshToken: "r",
                                     expiresAt: .distantFuture), for: p.id)
        let provider = CountingProvider(id: .claude, separatePlan: true)
        let registry = ProviderRegistry()
        registry.register(provider)
        let vm = makeVM(stubFetcher: StubOAuthProfileFetcher(), registry: registry)

        _ = await poll { provider.fetchUsageCount >= 1 }   // drain init refresh
        provider.metadataCount = 0
        vm.lastFetchAttemptAt = nil

        vm.refreshUsageNow(trigger: .manual)

        let probed = await poll { provider.metadataCount >= 1 }
        XCTAssertTrue(probed, "healthy manual Refresh should re-probe plan metadata")
    }

    /// A manual Refresh whose usage fetch hits 429 must NOT then probe plan
    /// metadata — that second request burns rate-limit budget while Anthropic
    /// is already throttling us (and the swallowed result hides the failure).
    /// The init refresh fails benignly (offline) so the manual gate is open;
    /// the manual fetch arms the 429.
    func test_manualRefresh_rateLimited_doesNotProbePlanMetadata() async throws {
        let p = Profile(name: "Hau", authMethod: .cliSync,
                        providerID: .claude, email: "h@x.com")
        try profileStore.add(p)
        try keychain.write(.cliToken(accessToken: "T", refreshToken: "r",
                                     expiresAt: .distantFuture), for: p.id)
        let provider = CountingProvider(id: .claude, separatePlan: true)
        let registry = ProviderRegistry()
        registry.register(provider)
        let vm = makeVM(stubFetcher: StubOAuthProfileFetcher(), registry: registry)

        _ = await poll { provider.fetchUsageCount >= 1 }   // drain init (offline)
        provider.fetchUsageCount = 0
        provider.metadataCount = 0
        vm.lastFetchAttemptAt = nil
        // Arm the manual fetch to 429.
        provider.fetchError = ClaudeAPIClient.APIError.rateLimited(retryAfter: 30)

        vm.refreshUsageNow(trigger: .manual)

        _ = await poll { provider.fetchUsageCount >= 1 }   // manual usage fetch (429)
        let probed = await poll(timeout: 0.8) { provider.metadataCount >= 1 }
        XCTAssertFalse(probed, "must not probe plan metadata while rate-limited")
        XCTAssertEqual(provider.metadataCount, 0)
    }

    /// A manual Refresh whose usage fetch hits 401 (`authState == .expired`)
    /// must NOT probe plan metadata — `/api/oauth/profile` would 401 too; the
    /// user has to re-auth first.
    func test_manualRefresh_unauthorized_doesNotProbePlanMetadata() async throws {
        let p = Profile(name: "Hau", authMethod: .cliSync,
                        providerID: .claude, email: "h@x.com")
        try profileStore.add(p)
        try keychain.write(.cliToken(accessToken: "T", refreshToken: "r",
                                     expiresAt: .distantFuture), for: p.id)
        let provider = CountingProvider(id: .claude, separatePlan: true)
        let registry = ProviderRegistry()
        registry.register(provider)
        let vm = makeVM(stubFetcher: StubOAuthProfileFetcher(), registry: registry)

        _ = await poll { provider.fetchUsageCount >= 1 }   // drain init (offline)
        provider.fetchUsageCount = 0
        provider.metadataCount = 0
        vm.lastFetchAttemptAt = nil
        provider.fetchError = ClaudeAPIClient.APIError.unauthorized

        vm.refreshUsageNow(trigger: .manual)

        _ = await poll { provider.fetchUsageCount >= 1 }   // manual usage fetch (401)
        let probed = await poll(timeout: 0.8) { provider.metadataCount >= 1 }
        XCTAssertFalse(probed, "must not probe plan metadata when auth expired")
        XCTAssertEqual(provider.metadataCount, 0)
    }

    /// The automatic background poll must NOT pay the extra `/api/oauth/profile`
    /// round-trip — only `.manual` re-probes. Stale plan persists until the
    /// user (or a CLI account change) triggers a refresh.
    func test_automaticRefresh_doesNotReprobePlanMetadata() async throws {
        let p = try seedProfile(plan: "Max 20x")
        let stub = StubOAuthProfileFetcher()
        stub.outcome = .success(makeResponse(planLabel: "Max 5x"))
        let vm = makeVM(stubFetcher: stub)
        vm.lastFetchAttemptAt = nil

        vm.refreshUsageNow(trigger: .automatic)

        // Give the spawned refresh Task ample time to run; the probe, if it
        // were going to fire, runs immediately after the (instant, stubbed)
        // usage fetch. A timeout with zero calls is the assertion.
        let fired = await poll(timeout: 1.5) { stub.callCount >= 1 }
        XCTAssertFalse(fired, "automatic refresh must NOT re-probe plan metadata")
        let stored = profileStore.profiles.first(where: { $0.id == p.id })!
        XCTAssertEqual(stored.subscriptionPlan, "Max 20x", "plan unchanged on automatic refresh")
    }

    /// Regression for the Codex adversarial finding: a provider WITHOUT a
    /// separate plan endpoint (Codex/Antigravity — their
    /// `refreshProfileMetadata` re-runs `fetchUsage`) must NOT get the
    /// post-refresh plan probe on a manual Refresh, or one Refresh fires the
    /// usage request twice. Proven via a counting provider: exactly one
    /// `fetchUsage` and zero `refreshProfileMetadata` calls.
    func test_manualRefresh_nonSeparatePlanProvider_doesNotDoubleFetchUsage() async throws {
        let p = Profile(name: "Gx", authMethod: .cliSync,
                        providerID: .codex, email: "g@x.com")
        try profileStore.add(p)
        try keychain.write(.cliToken(accessToken: "T", refreshToken: "r",
                                     expiresAt: .distantFuture), for: p.id)
        let provider = CountingProvider(id: .codex)
        let registry = ProviderRegistry()
        registry.register(provider)
        let vm = makeVM(stubFetcher: StubOAuthProfileFetcher(), registry: registry)

        // Drain the init-driven automatic refresh, then zero the counters so
        // we measure only the manual Refresh below.
        _ = await poll { provider.fetchUsageCount >= 1 }
        provider.fetchUsageCount = 0
        provider.metadataCount = 0
        vm.lastFetchAttemptAt = nil

        vm.refreshUsageNow(trigger: .manual)

        _ = await poll { provider.fetchUsageCount >= 1 }
        // If the gate regressed, refreshProfileMetadata would fire and re-run
        // fetchUsage → counts would climb past these. Give it room to happen.
        let doubled = await poll(timeout: 0.8) {
            provider.fetchUsageCount >= 2 || provider.metadataCount >= 1
        }
        XCTAssertFalse(doubled, "non-separate-plan provider must not double-fetch on manual Refresh")
        XCTAssertEqual(provider.fetchUsageCount, 1, "exactly one usage fetch")
        XCTAssertEqual(provider.metadataCount, 0, "no plan metadata probe")
    }

    /// Polls `cond` on the main actor until it holds or the deadline passes.
    /// `Task.sleep` yields so the detached refresh Task spawned by
    /// `refreshUsageNow` can make progress between checks.
    private func poll(timeout: TimeInterval = 3, until cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
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

/// Counts `fetchUsage` / `refreshProfileMetadata` calls and mirrors the
/// Codex/Antigravity contract where metadata refresh re-runs `fetchUsage`.
/// `separatePlan` drives `hasSeparatePlanMetadataRefresh`; `fetchError` is
/// what `fetchUsage` throws (mutable so a test can let the init-driven
/// automatic refresh fail benignly, then arm a 401/429 for the manual one).
@MainActor
private final class CountingProvider: AccountProvider {
    let id: ProviderID
    let displayName = "Counting"
    let iconAssetName = "Mascot"
    var separatePlan: Bool
    /// Thrown by `fetchUsage`. Default `.offline` is benign: `refresh(profile:)`
    /// routes it to the generic catch (authState stays `.authenticated`, no
    /// rate-limit armed), so it never blocks the probe by itself.
    var fetchError: Error
    var fetchUsageCount = 0
    var metadataCount = 0

    init(id: ProviderID,
         separatePlan: Bool = false,
         fetchError: Error = ProviderMetadataRefreshError.offline) {
        self.id = id
        self.separatePlan = separatePlan
        self.fetchError = fetchError
    }

    var hasSeparatePlanMetadataRefresh: Bool { separatePlan }

    var supportedAuthMethods: [any ProviderAuthMethod] { [] }

    func fetchUsage(credential: Credential, profile: Profile) async throws -> ProviderUsageSummary {
        fetchUsageCount += 1
        // Throwing keeps the fixture from needing a full ProviderUsageSummary;
        // refresh(profile:) classifies the error. The COUNT + thrown type are
        // what the tests assert.
        throw fetchError
    }

    func refreshProfileMetadata(for profile: Profile, credential: Credential) async throws -> Bool {
        metadataCount += 1
        _ = try? await fetchUsage(credential: credential, profile: profile)
        return false
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
