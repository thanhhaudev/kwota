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

    /// The actual point of this whole finding: for a `.cliSync` profile,
    /// `grantKeychainAccess()` must not stop at Kwota's own (never-blocking)
    /// Keychain item — it must also drive an `.allow` read against the CLI's
    /// own credential source (`Claude Code-credentials`, reached through
    /// `CLICredentialReader`/`CachedCLICredentialReader`), and a successful
    /// read there must be seeded into Kwota's own store so the very next
    /// background tick can see it without another dialog.
    @MainActor
    func test_grantKeychainAccess_reachesCLICredentialPath_forCliSyncProfile() async {
        let cliSpy = SpyCLICredentialReader(result: .success(
            CLICredentialReader.SyncResult(
                credential: .cliToken(accessToken: "granted-token", refreshToken: "r", expiresAt: .distantFuture),
                subscriptionPlan: nil
            )
        ))
        let recordingGateway = RecordingKeychainGateway()
        let vm = makeVM(gateway: recordingGateway, cliCredentialReader: cliSpy)
        let profile = Profile(name: "P", authMethod: .cliSync)
        try? vm.profileStore.add(profile)

        await vm.grantKeychainAccess()

        XCTAssertEqual(cliSpy.callCount, 1,
                       "grantKeychainAccess must reach the CLI credential path for a .cliSync profile")
        XCTAssertEqual(cliSpy.lastInteraction, .allow,
                       "the CLI read must be driven with .allow — that item is the one the incident's dialog was for")
        XCTAssertGreaterThanOrEqual(recordingGateway.writeCount, 1,
                       "a successful CLI grant must seed Kwota's own store so the next background .deny tick sees it")
    }

    /// `.sessionKey` profiles never touch the CLI credential source — the
    /// Grant flow must not probe an item this profile's auth method doesn't
    /// depend on.
    @MainActor
    func test_grantKeychainAccess_doesNotTouchCLIPath_forSessionKeyProfile() async {
        let cliSpy = SpyCLICredentialReader(result: .success(
            CLICredentialReader.SyncResult(
                credential: .cliToken(accessToken: "unused", refreshToken: "r", expiresAt: .distantFuture),
                subscriptionPlan: nil
            )
        ))
        let recordingGateway = RecordingKeychainGateway()
        let vm = makeVM(gateway: recordingGateway, cliCredentialReader: cliSpy)
        let profile = Profile(name: "P", authMethod: .sessionKey)
        try? vm.profileStore.add(profile)

        await vm.grantKeychainAccess()

        XCTAssertEqual(cliSpy.callCount, 0,
                       "a .sessionKey profile does not depend on the CLI credential source")
    }

    /// Regression: `.cliSync` is NOT Claude-specific — Codex (and
    /// Antigravity) auto-profiles use it too. `cliCredentialReader` only
    /// ever reads Claude Code's own Keychain item
    /// (`Claude Code-credentials`), so a Codex `.cliSync` profile must never
    /// reach that branch — otherwise Claude's OAuth token gets written into
    /// the Codex profile's own Keychain entry (destroying its real token)
    /// and then handed to `chatgpt.com`'s API as a Bearer token by the
    /// `refresh(profile:)` call right after.
    @MainActor
    func test_grantKeychainAccess_doesNotTouchCLIPath_forCodexProfile() async {
        let cliSpy = SpyCLICredentialReader(result: .success(
            CLICredentialReader.SyncResult(
                credential: .cliToken(accessToken: "claude-token-must-not-leak", refreshToken: "r", expiresAt: .distantFuture),
                subscriptionPlan: nil
            )
        ))
        let recordingGateway = RecordingKeychainGateway()
        let vm = makeVM(gateway: recordingGateway, cliCredentialReader: cliSpy)
        let profile = Profile(name: "P", authMethod: .cliSync, providerID: .codex)
        try? vm.profileStore.add(profile)

        await vm.grantKeychainAccess()

        XCTAssertEqual(cliSpy.callCount, 0,
                       "a Codex .cliSync profile must not read Claude Code's own Keychain item")
        XCTAssertEqual(recordingGateway.writeCount, 0,
                       "Claude's token must never be written into a Codex profile's Keychain entry")
    }

    /// A denied `.allow` read on the CLI path (distinct from Kwota's own
    /// store succeeding) must still land on the Grant banner, not a generic
    /// error — the same "user dismissed/timed out" treatment as a denial on
    /// Kwota's own item.
    @MainActor
    func test_deniedCLIRead_staysInKeychainAccessNeeded() async {
        let cliSpy = SpyCLICredentialReader(result: .failure(KeychainGatewayError.interactionNotAllowed))
        let recordingGateway = RecordingKeychainGateway()
        let vm = makeVM(gateway: recordingGateway, cliCredentialReader: cliSpy)
        let profile = Profile(name: "P", authMethod: .cliSync)
        try? vm.profileStore.add(profile)

        await vm.grantKeychainAccess()

        XCTAssertEqual(cliSpy.callCount, 1)
        XCTAssertEqual(vm.authState, .keychainAccessNeeded)
        XCTAssertEqual(recordingGateway.writeCount, 0,
                       "a denied CLI read must not seed Kwota's own store with nothing")
    }

    // MARK: - Fixture

    /// Minimal hermetic `MenuBarViewModel` fixture. Unlike
    /// `KeychainDenialSemanticsTests`' fixture (which only substitutes the
    /// `credentialReader` seam that `refresh(profile:)` consults),
    /// `grantKeychainAccess()` calls the concrete `credentialStore` field
    /// directly — so this fixture builds that concrete `KeychainCredentialStore`
    /// on top of an injectable `KeychainGateways` double instead.
    ///
    /// `gateway`, when passed, wins over `gatewayError` — the CLI-path tests
    /// need a store that actually succeeds/records writes rather than one
    /// that throws on every call.
    @MainActor
    private func makeVM(
        gatewayError: KeychainGatewayError = .status(errSecParam),
        gateway: (any KeychainGateways)? = nil,
        cliCredentialReader: (any CLICredentialReading)? = nil
    ) -> MenuBarViewModel {
        let temp = TempDirectory()
        let service = "com.thanhhaudev.Kwota.test.\(UUID())"
        let throwingKeychain = KeychainCredentialStore(
            service: service,
            gateway: gateway ?? ThrowingKeychainGateway(error: gatewayError)
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
            cliCredentialReader: cliCredentialReader,
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

/// An in-memory, non-throwing `KeychainGateways` double for
/// `credentialStore` — unlike `ThrowingKeychainGateway`, this one actually
/// stores what it's given so the CLI-path tests can confirm a successful
/// grant seeded Kwota's own item.
private final class RecordingKeychainGateway: KeychainGateways, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var _writeCount = 0

    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return _writeCount }

    func read(service: String, account: String?, interaction: KeychainInteraction) async throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let account else { return nil }
        return storage[account]
    }
    func write(_ data: Data, service: String, account: String) async throws {
        lock.lock(); storage[account] = data; _writeCount += 1; lock.unlock()
    }
    func delete(service: String, account: String) async throws {
        lock.lock(); storage.removeValue(forKey: account); lock.unlock()
    }
    func deleteAll(service: String) async throws {
        lock.lock(); storage.removeAll(); lock.unlock()
    }
}

/// A `CLICredentialReading` double that records the interaction it was
/// called with — the seam these tests need to prove `grantKeychainAccess()`
/// actually reaches Claude Code's own Keychain item, not just Kwota's.
private final class SpyCLICredentialReader: CLICredentialReading, @unchecked Sendable {
    private let result: Result<CLICredentialReader.SyncResult, Error>
    private let lock = NSLock()
    private var _callCount = 0
    private var _lastInteraction: KeychainInteraction?

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    var lastInteraction: KeychainInteraction? { lock.lock(); defer { lock.unlock() }; return _lastInteraction }

    init(result: Result<CLICredentialReader.SyncResult, Error>) {
        self.result = result
    }

    func read() async throws -> CLICredentialReader.SyncResult {
        lock.lock(); _callCount += 1; _lastInteraction = .deny; lock.unlock()
        return try result.get()
    }

    func readFresh(interaction: KeychainInteraction) async throws -> CLICredentialReader.SyncResult {
        lock.lock(); _callCount += 1; _lastInteraction = interaction; lock.unlock()
        return try result.get()
    }
}
