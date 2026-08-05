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

    // MARK: - Finding 3: re-verify identity/liveness before the write

    /// If the profile was removed from the store while the `.allow` CLI read
    /// was in flight (it can take up to `allowTimeout`, 120s, waiting on a
    /// real dialog), the resolved token must never be written under an id
    /// that no longer names a live profile — and the UI must land back on
    /// the Grant banner, not silently proceed as if nothing happened.
    @MainActor
    func test_grantKeychainAccess_skipsWrite_whenProfileRemovedWhileCLIReadWasInFlight() async throws {
        let recordingGateway = RecordingKeychainGateway()
        // The reader needs to reach back into the VM's own `profileStore` to
        // remove the profile mid-flight, but that store doesn't exist until
        // the VM is built — and the reader has to already be constructed to
        // hand to the VM's initializer. The box breaks the cycle: it starts
        // empty and is filled in right after the VM exists, before
        // `grantKeychainAccess()` is called.
        let box = ProfileStoreBox()
        let cliSpy = ProfileRemovingCLICredentialReader(box: box, result: .success(
            CLICredentialReader.SyncResult(
                credential: .cliToken(accessToken: "stale-account-token", refreshToken: "r", expiresAt: .distantFuture),
                subscriptionPlan: nil
            )
        ))
        let vm = makeVM(gateway: recordingGateway, cliCredentialReader: cliSpy)
        let profile = Profile(name: "P", authMethod: .cliSync)
        try? vm.profileStore.add(profile)
        box.store = vm.profileStore
        box.profileId = profile.id

        await vm.grantKeychainAccess()

        XCTAssertEqual(recordingGateway.writeCount, 0,
                       "a token resolved after the profile was removed must never be written")
        XCTAssertEqual(vm.authState, .keychainAccessNeeded,
                       "must land back on the Grant banner, not a stale success path")
    }

    /// If the CLI's on-disk identity no longer matches the profile by the
    /// time the `.allow` read resolves (the user ran `codex`/`claude login`
    /// as a different account while the dialog was open), the resolved
    /// token must not be written under the old profile's id — the same
    /// cross-account misattribution `CLITokenRefresher.identityCheck` guards
    /// against on the background refresh path, reused here via
    /// `autoProfileCoordinator.guardRefresh`.
    @MainActor
    func test_grantKeychainAccess_skipsWrite_whenIdentityNoLongerMatchesAfterCLIRead() async throws {
        let recordingGateway = RecordingKeychainGateway()
        let cliSpy = SpyCLICredentialReader(result: .success(
            CLICredentialReader.SyncResult(
                credential: .cliToken(accessToken: "other-account-token", refreshToken: "r", expiresAt: .distantFuture),
                subscriptionPlan: nil
            )
        ))
        let vm = makeVM(
            gateway: recordingGateway,
            cliCredentialReader: cliSpy,
            coordinatorOAuthRead: {
                OAuthAccountReader.Account(
                    seatTier: nil,
                    emailAddress: "someone-else@example.com",
                    displayName: nil,
                    organizationName: nil,
                    subscriptionCreatedAt: nil,
                    organizationType: nil,
                    organizationRateLimitTier: nil,
                    accountUuid: nil,
                    organizationUuid: nil
                )
            }
        )
        let profile = Profile(name: "P", authMethod: .cliSync, email: "owner@example.com")
        try? vm.profileStore.add(profile)

        await vm.grantKeychainAccess()

        XCTAssertEqual(cliSpy.callCount, 1, "the CLI read itself must still happen")
        XCTAssertEqual(recordingGateway.writeCount, 0,
                       "a token for a different on-disk account must never be written under this profile")
        XCTAssertEqual(vm.authState, .keychainAccessNeeded,
                       "must land back on the Grant banner, not a stale success path")
    }

    // MARK: - Finding 4: in-flight guard

    /// A second tap on the Grant banner while the first attempt is still
    /// parked inside the (up to 120s) `.allow` CLI read must not queue a
    /// second probe — `readFresh(interaction: .allow)` deliberately bypasses
    /// the reader's normal cache/in-flight dedup, so without this guard at
    /// the view-model layer every repeat tap genuinely reaches the gateway.
    @MainActor
    func test_grantKeychainAccess_guardsAgainstConcurrentReentry() async throws {
        let gate = CLIReadGate()
        let cliSpy = GatedSpyCLICredentialReader(gate: gate, result: .success(
            CLICredentialReader.SyncResult(
                credential: .cliToken(accessToken: "granted", refreshToken: "r", expiresAt: .distantFuture),
                subscriptionPlan: nil
            )
        ))
        let recordingGateway = RecordingKeychainGateway()
        let vm = makeVM(gateway: recordingGateway, cliCredentialReader: cliSpy)
        let profile = Profile(name: "P", authMethod: .cliSync)
        try? vm.profileStore.add(profile)

        let task1 = Task { @MainActor in await vm.grantKeychainAccess() }

        // Wait for the first attempt to reach the parked CLI read.
        var deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if await gate.callCount >= 1 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let callCountBeforeSecondTap = await gate.callCount
        XCTAssertEqual(callCountBeforeSecondTap, 1, "precondition: first attempt must be parked in the CLI read")
        XCTAssertTrue(vm.isGrantingKeychainAccess, "the in-flight flag must be set while the first attempt is parked")

        // A second tap while the first is still in flight must be a no-op.
        await vm.grantKeychainAccess()

        await gate.release()
        await task1.value

        let finalCallCount = await gate.callCount
        XCTAssertEqual(finalCallCount, 1,
                       "a concurrent second grantKeychainAccess() call must not queue another CLI read")
        XCTAssertFalse(vm.isGrantingKeychainAccess, "flag must clear once the in-flight attempt completes")
    }

    // MARK: - Third adversarial-review round: write failure must not be swallowed

    /// The actual bug: `grantKeychainAccess()` used `try?` on the write that
    /// seeds the newly granted CLI token into Kwota's own store. If that
    /// specific write fails, the old code fell through unchanged to
    /// `refresh(profile:)`, which would proceed on whatever credential was
    /// already stored (the old one) — clearing the Grant banner and giving
    /// the user a false impression of success with no error shown, while the
    /// actual granted token was never saved. This asserts the write failure
    /// now propagates into the existing catch structure instead: a
    /// `.timedOut` write failure must land back on `.keychainAccessNeeded`,
    /// matching the same "stay on the Grant banner, let the user retry"
    /// treatment other timeout/cancel paths already get — never a stale,
    /// silently-successful-looking `refresh(profile:)`.
    @MainActor
    func test_grantKeychainAccess_writeFailure_doesNotSilentlySucceed() async throws {
        let cliSpy = SpyCLICredentialReader(result: .success(
            CLICredentialReader.SyncResult(
                credential: .cliToken(accessToken: "granted-token", refreshToken: "r", expiresAt: .distantFuture),
                subscriptionPlan: nil
            )
        ))
        let failingGateway = WriteFailingKeychainGateway(writeError: .timedOut)
        let vm = makeVM(gateway: failingGateway, cliCredentialReader: cliSpy)
        let profile = Profile(name: "P", authMethod: .cliSync)
        try? vm.profileStore.add(profile)

        await vm.grantKeychainAccess()

        XCTAssertEqual(cliSpy.callCount, 1, "the CLI read itself must still happen")
        XCTAssertEqual(failingGateway.writeCount, 1, "the write must actually have been attempted")
        XCTAssertEqual(vm.authState, .keychainAccessNeeded,
                       "a write failure must not be swallowed into a stale-but-successful-looking refresh")
    }

    /// Same failure, but a genuinely unexpected status (not a timeout/cancel
    /// shape) — must surface as a real error via the existing catch-all,
    /// exactly like any other genuinely unexpected Keychain failure does
    /// elsewhere in this function.
    @MainActor
    func test_grantKeychainAccess_writeFailure_withUnexpectedStatus_surfacesAsError() async throws {
        let cliSpy = SpyCLICredentialReader(result: .success(
            CLICredentialReader.SyncResult(
                credential: .cliToken(accessToken: "granted-token", refreshToken: "r", expiresAt: .distantFuture),
                subscriptionPlan: nil
            )
        ))
        let failingGateway = WriteFailingKeychainGateway(writeError: .status(errSecParam))
        let vm = makeVM(gateway: failingGateway, cliCredentialReader: cliSpy)
        let profile = Profile(name: "P", authMethod: .cliSync)
        try? vm.profileStore.add(profile)

        await vm.grantKeychainAccess()

        XCTAssertEqual(failingGateway.writeCount, 1, "the write must actually have been attempted")
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
    ///
    /// `gateway`, when passed, wins over `gatewayError` — the CLI-path tests
    /// need a store that actually succeeds/records writes rather than one
    /// that throws on every call.
    @MainActor
    private func makeVM(
        gatewayError: KeychainGatewayError = .status(errSecParam),
        gateway: (any KeychainGateways)? = nil,
        cliCredentialReader: (any CLICredentialReading)? = nil,
        // Finding 3 coverage: when non-nil, the coordinator's watcher reads
        // this identity instead of the always-permissive default, and
        // `alwaysAllowRefresh` flips to false so `guardRefresh` actually
        // compares it against the profile's email — letting a test simulate
        // "the CLI signed into a different account while the Grant dialog
        // was open."
        coordinatorOAuthRead: (() -> OAuthAccountReader.Account?)? = nil
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
        let coordWatcher = CLIAccountWatcher(
            oauthRead: coordinatorOAuthRead ?? { nil },
            fileEvents: AsyncStream { _ in }
        )
        let permissiveCoord = AutoProfileCoordinator(
            watcher: coordWatcher,
            profileStore: profileStore,
            alwaysAllowRefresh: coordinatorOAuthRead == nil
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

/// A `KeychainGateways` double whose `read` always succeeds (so the flow
/// reaches the CLI credential path) but whose `write` always fails with a
/// configurable `KeychainGatewayError` — the seam the write-failure-swallowed
/// regression test needs, distinct from `ThrowingKeychainGateway` (which
/// fails every call, never reaching the CLI path at all).
private final class WriteFailingKeychainGateway: KeychainGateways, @unchecked Sendable {
    private let writeError: KeychainGatewayError
    private let lock = NSLock()
    private var _writeCount = 0

    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return _writeCount }

    init(writeError: KeychainGatewayError) { self.writeError = writeError }

    func read(service: String, account: String?, interaction: KeychainInteraction) async throws -> Data? { nil }
    func write(_ data: Data, service: String, account: String) async throws {
        lock.lock(); _writeCount += 1; lock.unlock()
        throw writeError
    }
    func delete(service: String, account: String) async throws {}
    func deleteAll(service: String) async throws {}
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

// MARK: - Finding 3 fixtures

/// Breaks the construction-order cycle between a `CLICredentialReading`
/// double and the `ProfileStore` it needs to mutate — the reader has to
/// exist before `MenuBarViewModel.init` runs, but the store it needs to
/// reach doesn't exist until after. `@unchecked Sendable`: only ever
/// mutated/read on the main actor in these tests, mirroring
/// `RecordingKeychainGateway`'s existing pattern in this file.
private final class ProfileStoreBox: @unchecked Sendable {
    var store: ProfileStore?
    var profileId: UUID?
}

/// A `CLICredentialReading` double that removes the profile from the store
/// (via `ProfileStoreBox`) the instant its `.allow` read resolves —
/// standing in for the profile being deleted while the user was still
/// looking at the real OS consent dialog.
private final class ProfileRemovingCLICredentialReader: CLICredentialReading, @unchecked Sendable {
    private let box: ProfileStoreBox
    private let result: Result<CLICredentialReader.SyncResult, Error>

    init(box: ProfileStoreBox, result: Result<CLICredentialReader.SyncResult, Error>) {
        self.box = box
        self.result = result
    }

    func read() async throws -> CLICredentialReader.SyncResult { try result.get() }

    func readFresh(interaction: KeychainInteraction) async throws -> CLICredentialReader.SyncResult {
        if let store = box.store, let id = box.profileId {
            try? await store.remove(id: id)
        }
        return try result.get()
    }
}

// MARK: - Finding 4 fixtures

/// Orders the reentrancy test deterministically: the CLI read parks until
/// released, letting the test call `grantKeychainAccess()` a second time
/// while the first attempt is still in flight, then release and confirm
/// only one read actually happened. Mirrors the `TransportGate` pattern in
/// `MenuBarViewModelRefreshGateTests`.
private actor CLIReadGate {
    private(set) var callCount = 0
    private var released = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    func register() -> Int {
        callCount += 1
        return callCount
    }

    func parkUntilReleased() async {
        if released { return }
        await withCheckedContinuation { parked.append($0) }
    }

    func release() {
        released = true
        parked.forEach { $0.resume() }
        parked.removeAll()
    }
}

/// A `CLICredentialReading` double whose `.allow` read parks on `gate`
/// until the test releases it — the reentrancy test's way of holding a
/// Grant attempt "in flight" for long enough to prove a concurrent second
/// call doesn't queue another read.
private final class GatedSpyCLICredentialReader: CLICredentialReading, @unchecked Sendable {
    private let gate: CLIReadGate
    private let result: Result<CLICredentialReader.SyncResult, Error>

    init(gate: CLIReadGate, result: Result<CLICredentialReader.SyncResult, Error>) {
        self.gate = gate
        self.result = result
    }

    func read() async throws -> CLICredentialReader.SyncResult { try result.get() }

    func readFresh(interaction: KeychainInteraction) async throws -> CLICredentialReader.SyncResult {
        _ = await gate.register()
        await gate.parkUntilReleased()
        return try result.get()
    }
}
