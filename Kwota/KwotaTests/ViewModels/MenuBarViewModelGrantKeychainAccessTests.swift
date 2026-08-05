//
//  MenuBarViewModelGrantKeychainAccessTests.swift
//  KwotaTests
//
//  Regression coverage for a review finding on `grantKeychainAccess()`:
//  the OS Keychain maps both a user-cancelled consent dialog and a timeout
//  to the same error shape as `refresh(profile:)`'s `.deny` path. Before
//  this fix, `grantKeychainAccess()`'s catch-all treated a cancelled dialog
//  identically to a genuine failure, surfacing `ReAuthBanner`'s "session
//  expired" copy for what was really just "user dismissed the dialog."
//

import Security
import XCTest
@testable import Kwota

final class MenuBarViewModelGrantKeychainAccessTests: XCTestCase {

    /// Throws a configurable `KeychainGatewayError` from every `read`,
    /// standing in for a cancelled/dismissed consent dialog, a timeout, or
    /// a genuinely unexpected Security.framework status.
    private final class ThrowingKeychainGateway: KeychainGateways, @unchecked Sendable {
        let error: KeychainGatewayError
        init(error: KeychainGatewayError) { self.error = error }

        func read(service: String, account: String?, interaction: KeychainInteraction) async throws -> Data? {
            throw error
        }
        func write(_ data: Data, service: String, account: String) async throws {}
        func delete(service: String, account: String) async throws {}
        func deleteAll(service: String) async throws {}
    }

    /// A cancelled or dismissed OS consent dialog must leave the user back
    /// at the Grant banner — never at the "session expired" banner, which
    /// would misdiagnose an ordinary dismissal as an authorization problem.
    @MainActor
    func test_cancelledDialogStaysInKeychainAccessNeeded() async {
        let vm = makeVM(gatewayError: .interactionNotAllowed)
        let profile = Profile(name: "P", authMethod: .cliSync)
        try? vm.profileStore.add(profile)

        await vm.grantKeychainAccess()

        XCTAssertEqual(vm.authState, .keychainAccessNeeded)
    }

    /// A timeout waiting on the dialog gets the same treatment as an
    /// explicit cancel — retry stays available via the same banner.
    @MainActor
    func test_timedOutDialogStaysInKeychainAccessNeeded() async {
        let vm = makeVM(gatewayError: .timedOut)
        let profile = Profile(name: "P", authMethod: .cliSync)
        try? vm.profileStore.add(profile)

        await vm.grantKeychainAccess()

        XCTAssertEqual(vm.authState, .keychainAccessNeeded)
    }

    /// A genuinely unexpected Keychain failure (not a cancel/timeout) still
    /// surfaces as a real error, not silently swallowed into the Grant banner.
    @MainActor
    func test_genuineFailureSurfacesAsError() async {
        let vm = makeVM(gatewayError: .status(errSecParam))
        let profile = Profile(name: "P", authMethod: .cliSync)
        try? vm.profileStore.add(profile)

        await vm.grantKeychainAccess()

        guard case .error = vm.authState else {
            return XCTFail("expected .error, got \(vm.authState)")
        }
    }

    // MARK: - Fixture

    /// Minimal hermetic `MenuBarViewModel` fixture. Unlike
    /// `KeychainDenialSemanticsTests`' fixture (which only substitutes the
    /// `credentialReader` seam that `refresh(profile:)` consults),
    /// `grantKeychainAccess()` calls the concrete `credentialStore` field
    /// directly — so this fixture builds that concrete `KeychainCredentialStore`
    /// on top of an injectable `KeychainGateways` double instead.
    @MainActor
    private func makeVM(gatewayError: KeychainGatewayError) -> MenuBarViewModel {
        let temp = TempDirectory()
        let service = "com.thanhhaudev.Kwota.test.\(UUID())"
        let throwingKeychain = KeychainCredentialStore(
            service: service,
            gateway: ThrowingKeychainGateway(error: gatewayError)
        )
        let dataRoot = temp.url
        let profileStore = ProfileStore(
            profilesFile: temp.file("profiles.json"),
            keychain: throwingKeychain,
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
            keychain: throwingKeychain,
            clock: { Date() }
        )
        let sandboxedDefaults = UserDefaults(suiteName: "kwota-grant-keychain-test-\(UUID())")!
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
                gateway: StubKeychainGateway(read: { nil })
            ),
            store: throwingKeychain
        )
        return MenuBarViewModel(
            usage: usage,
            statsStore: makeHermeticStatsStore(),
            cachePersistence: CachePersistenceStore(url: temp.file("cache-state-\(UUID().uuidString).json")),
            profileStore: profileStore,
            credentialStore: throwingKeychain,
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
