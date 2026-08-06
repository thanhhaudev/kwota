//
//  KeychainDenialSemanticsTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class KeychainDenialSemanticsTests: XCTestCase {

    private final class DenyingCredentialStore: CredentialReading {
        func read(for id: UUID, interaction: KeychainInteraction) async throws -> Credential? {
            throw KeychainCredentialStore.KeychainError.interactionNotAllowed
        }
    }

    private final class EmptyCredentialStore: CredentialReading {
        func read(for id: UUID, interaction: KeychainInteraction) async throws -> Credential? {
            nil
        }
    }

    /// Kwota's OWN item reads fine — the denial in the tests below happens
    /// further down, on the CLI's cross-app item, which is a different
    /// failure at a different layer.
    private final class HealthyCredentialStore: CredentialReading {
        func read(for id: UUID, interaction: KeychainInteraction) async throws -> Credential? {
            .cliToken(accessToken: "stored", refreshToken: "r", expiresAt: .distantFuture)
        }
    }

    private final class ThrowingGateway: KeychainGateways, @unchecked Sendable {
        let error: KeychainGatewayError
        init(error: KeychainGatewayError) { self.error = error }
        func read(service: String, account: String?, interaction: KeychainInteraction) async throws -> Data? {
            throw error
        }
        func write(_ data: Data, service: String, account: String) async throws {}
        func delete(service: String, account: String) async throws {}
        func deleteAll(service: String) async throws {}
    }

    @MainActor
    func test_deniedReadSurfacesKeychainAccessNeeded() async {
        let fetcher = LiveProfileUsageFetcher(
            registry: ProviderRegistry(),
            credentialStore: DenyingCredentialStore(),
            liveIdentityProvider: { [:] }
        )
        let profile = Profile(name: "P", authMethod: .cliSync)
        do {
            _ = try await fetcher.fetch(profile: profile)
            XCTFail("expected keychainAccessNeeded")
        } catch let error as ProfileUsageFetcherError {
            XCTAssertEqual(error, .keychainAccessNeeded(profileID: profile.id))
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    @MainActor
    func test_absentCredentialStillMeansMissingCredential() async {
        let fetcher = LiveProfileUsageFetcher(
            registry: ProviderRegistry(),
            credentialStore: EmptyCredentialStore(),
            liveIdentityProvider: { [:] }
        )
        let profile = Profile(name: "P", authMethod: .cliSync)
        do {
            _ = try await fetcher.fetch(profile: profile)
            XCTFail("expected missingCredential")
        } catch let error as ProfileUsageFetcherError {
            XCTAssertEqual(error, .missingCredential(profileID: profile.id))
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// The dangerous confusion: a denied read must never be read as a sign-out,
    /// or Kwota archives a live profile and hands the active slot elsewhere.
    @MainActor
    func test_deniedReadDoesNotMarkTheProfileExpired() async {
        let vm = makeVM(credentialStore: DenyingCredentialStore())
        let profile = Profile(name: "P", authMethod: .cliSync)
        // `refresh(profile:)`'s canCommitToUI() gate (race protection: a
        // stale-generation Task for a profile that is no longer active must
        // not clobber the UI) requires `profile.id == profileStore.
        // activeProfileId`. Every production call site satisfies this by
        // construction (refreshUsageNow always resolves `profile` from the
        // store's own activeProfileId); a direct unit-test call needs the
        // same precondition seeded explicitly, or the assertion below would
        // trivially fail with authState stuck at its post-init value
        // instead of exercising the denial-mapping branch this test exists
        // to cover.
        try? vm.profileStore.add(profile)
        await vm.refresh(profile: profile)
        XCTAssertEqual(vm.authState, .keychainAccessNeeded)
        XCTAssertNotEqual(vm.authState, .expired)
    }

    /// The stale-popover regression, end to end at the shell.
    ///
    /// Kwota's own Keychain item reads fine, so `refresh(profile:)` sails past
    /// the denial check at the top. The failure is one layer down: the CLI's
    /// cross-app item (`Claude Code-credentials`) refuses the read, Kwota can
    /// no longer follow Claude Code's token rotation, the stored token goes
    /// stale, and the API answers 401. Matching on that 401 alone would report
    /// an expired session and send the user to `claude login` — which cannot
    /// fix an ACL denial. The denial has to survive all the way up so the
    /// Grant banner is what the user actually gets.
    @MainActor
    func test_deniedCLIKeychainShowsGrantRatherThanExpiredSession() async {
        let vm = makeVM(
            credentialStore: HealthyCredentialStore(),
            cliGateway: ThrowingGateway(error: .interactionNotAllowed)
        )
        let profile = Profile(name: "P", authMethod: .cliSync)
        try? vm.profileStore.add(profile)
        await vm.refresh(profile: profile)
        XCTAssertEqual(vm.authState, .keychainAccessNeeded)
        XCTAssertNotEqual(vm.authState, .expired)
    }

    /// The other side of the same boundary: when the CLI item is genuinely
    /// absent rather than refused, a 401 really does mean the session is over,
    /// and `.expired` (with its "run claude login" copy) is the correct call.
    /// Without this, the fix above could over-reach and hide real sign-outs
    /// behind a Grant button that would never help.
    @MainActor
    func test_absentCLIKeychainWith401StillMeansExpired() async {
        let vm = makeVM(credentialStore: HealthyCredentialStore())
        let profile = Profile(name: "P", authMethod: .cliSync)
        try? vm.profileStore.add(profile)
        await vm.refresh(profile: profile)
        XCTAssertEqual(vm.authState, .expired)
    }

    // MARK: - Fixture

    /// Minimal hermetic `MenuBarViewModel` fixture for this suite. `credentialStore`
    /// substitutes only the read-only seam `refresh(profile:)` consults
    /// (`MenuBarViewModel.credentialReader`) so a denying/empty double can be
    /// injected without touching the concrete, write-capable
    /// `KeychainCredentialStore` every other collaborator (AutoProfileCoordinator,
    /// CodexAutoProfileCoordinator, AntigravityAutoProfileCoordinator) is built with.
    @MainActor
    private func makeVM(
        credentialStore: (any CredentialReading)? = nil,
        cliGateway: (any KeychainGateways)? = nil
    ) -> MenuBarViewModel {
        let temp = TempDirectory()
        let service = "com.thanhhaudev.Kwota.test.\(UUID())"
        let keychain = KeychainCredentialStore(service: service)
        let dataRoot = temp.url
        let profileStore = ProfileStore(
            profilesFile: temp.file("profiles.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in dataRoot.appendingPathComponent(id.uuidString) }
        )
        // Hermetic watchers: unwired onChange, so no live-IO auto-detect
        // emit reaches ProfileStore during this test.
        let vmWatcher = CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in })
        let coordWatcher = CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in })
        let permissiveCoord = AutoProfileCoordinator(
            watcher: coordWatcher,
            profileStore: profileStore,
            alwaysAllowRefresh: true
        )
        let codexWatcherStub = CodexAccountWatcher(authRead: { nil }, fileEvents: AsyncStream { _ in })
        let codexCoordStub = CodexAutoProfileCoordinator(
            watcher: codexWatcherStub,
            profileStore: profileStore,
            keychain: keychain,
            clock: { Date() }
        )
        let sandboxedDefaults = UserDefaults(suiteName: "kwota-keychain-denial-test-\(UUID())")!
        sandboxedDefaults.set(true, forKey: "autoDetectMigrationCompleted")
        let inertMigrator = AutoProfileMigrator(
            profileStore: profileStore,
            oauthRead: { nil },
            defaults: sandboxedDefaults
        )
        let usage = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: temp.file("ledger-\(UUID().uuidString).json"),
            dailyCounterURL: temp.file("daily-counter-\(UUID().uuidString).json")
        )
        let stubRefresher = CLITokenRefresher(
            reader: CLICredentialReader(
                credentialsFile: temp.file("missing-credentials.json"),
                gateway: cliGateway ?? StubKeychainGateway(read: { nil })
            ),
            store: keychain
        )
        return MenuBarViewModel(
            usage: usage,
            statsStore: makeHermeticStatsStore(),
            cachePersistence: CachePersistenceStore(url: temp.file("cache-state-\(UUID().uuidString).json")),
            profileStore: profileStore,
            credentialStore: keychain,
            credentialReader: credentialStore,
            apiClient: ClaudeAPIClient(transport: { req in
                let resp = HTTPURLResponse(
                    url: req.url ?? URL(string: "https://example.invalid")!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), resp)
            }),
            cliRefresher: stubRefresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: vmWatcher,
            codexAccountWatcher: codexWatcherStub,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: permissiveCoord,
            codexAutoProfileCoordinator: codexCoordStub,
            autoProfileMigrator: inertMigrator,
            activityHistorian: ActivityHistorian(autoBackfill: false)
        )
    }
}
