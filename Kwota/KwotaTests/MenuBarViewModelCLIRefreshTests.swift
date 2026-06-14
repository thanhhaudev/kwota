//
//  MenuBarViewModelCLIRefreshTests.swift
//  KwotaTests
//
//  Integration tests for the .cliSync refresh path in MenuBarViewModel:
//  401 → forceRefresh → retry-on-rotation, and the negative branch where
//  the CLI keychain has not rotated and the retry must be skipped.
//
//  These assert outcomes (authState, persisted credential, set of auth
//  headers seen by the API) rather than exact call counts, because
//  MenuBarViewModel intentionally double-fires its first refresh on init
//  (active-profile subscription + UsageRefreshCoordinator.start).
//

import XCTest
@testable import Kwota

@MainActor
final class MenuBarViewModelCLIRefreshTests: XCTestCase {
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

    // MARK: - Helpers

    /// Transport that returns 401 when the Authorization header contains any
    /// substring in `rejectTokens`, otherwise 200 with the supplied
    /// rate-limit headers. Records every Authorization header value for
    /// behavior-level assertions.
    private final class RecordingTransport: @unchecked Sendable {
        private(set) var seenAuthHeaders: [String] = []
        let rejectTokens: Set<String>
        let okHeaders: [String: String]

        init(rejectTokens: Set<String>, okHeaders: [String: String]) {
            self.rejectTokens = rejectTokens
            self.okHeaders = okHeaders
        }

        func handle(_ req: URLRequest) -> (Data, URLResponse) {
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            seenAuthHeaders.append(auth)
            let url = req.url ?? URL(string: "https://api.anthropic.com/v1/messages")!
            if rejectTokens.contains(where: { auth.contains($0) }) {
                let resp = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            }
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: okHeaders)!
            return (Data(), resp)
        }
    }

    private func makeReader(_ probeJSON: String?) -> CLICredentialReader {
        CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: { probeJSON.map { Data($0.utf8) } }
        )
    }

    /// Polls vm.authState until it equals `expected`, or fails the test.
    ///
    /// Default timeout bumped to 8.0 after the refresh-gate change removed
    /// the "double-fire on init" safety net (rebindHistory + coord.start
    /// each triggered a refresh; the gate now suppresses the second within
    /// the 10s throttle window). Under the full `make test` parallel load,
    /// a single refresh's main-actor scheduling can routinely exceed the
    /// prior 2.0s budget while a serial run finishes in ~100ms. 8.0s
    /// leaves headroom for the slowest observed runs (~5–6s) without
    /// dragging passing tests since the loop short-circuits on match.
    private func waitForAuthState(
        _ vm: MenuBarViewModel,
        _ expected: AuthState,
        timeout: TimeInterval = 8.0,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if vm.authState == expected { return }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
        XCTFail("authState did not reach \(expected); last value=\(vm.authState)", file: file, line: line)
    }

    /// Waits until the recorded auth-header count has been stable for
    /// `quietWindow`, so post-init double-refresh, retries, and store writes
    /// have all settled before the test inspects results.
    private func waitForQuiescence(
        _ probe: @escaping () -> Int,
        quietWindow: TimeInterval = 0.2,
        timeout: TimeInterval = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        var lastCount = probe()
        var stableSince = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            let now = probe()
            if now == lastCount {
                if Date().timeIntervalSince(stableSince) >= quietWindow { return }
            } else {
                lastCount = now
                stableSince = Date()
            }
        }
    }

    /// Returns a coordinator with `alwaysAllowRefresh: true` so tests that
    /// call `refresh` directly aren't blocked by the idle CLI watcher.
    private func makePermissiveCoordinator() -> AutoProfileCoordinator {
        let watcher = CLIAccountWatcher(
            oauthRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        return AutoProfileCoordinator(
            watcher: watcher,
            profileStore: profileStore,
            alwaysAllowRefresh: true
        )
    }

    /// Returns a hermetic UsageMonitor scoped to the per-test TempDirectory so
    /// the live default does not read ~/.claude/projects/**/*.jsonl or write
    /// to the shared ~/Library/Application Support/com.thanhhaudev.Kwota/
    /// ledger during parallel test runs.
    private func makeHermeticUsage() -> UsageMonitor {
        UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: temp.file("ledger-\(UUID().uuidString).json"),
            dailyCounterURL: temp.file("daily-counter-\(UUID().uuidString).json")
        )
    }

    /// Returns hermetic Codex stubs so the live startup path does not read
    /// ~/.codex/auth.json or create a phantom Codex profile during tests.
    private func makeCodexStubs() -> (CodexAccountWatcher, CodexAutoProfileCoordinator) {
        let watcher = CodexAccountWatcher(
            authRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let coord = CodexAutoProfileCoordinator(
            watcher: watcher,
            profileStore: profileStore,
            keychain: keychain,
            clock: { Date() }
        )
        return (watcher, coord)
    }

    /// Returns a history-file mapping rooted in the per-test TempDirectory so
    /// 200-path refreshes append usage history under the temp dir instead of
    /// the real ~/Library/Application Support/com.thanhhaudev.Kwota/profiles/.
    private func makeHistoryFileProvider() -> (UUID) -> URL {
        let temp = self.temp!
        return { id in temp.file("history-\(id.uuidString).json") }
    }

    /// Hermetic cache-persistence store rooted in the per-test TempDirectory
    /// so VM init never loads (or later saves) the user's real
    /// cache-state.json in Application Support.
    private func makeHermeticCachePersistence() -> CachePersistenceStore {
        CachePersistenceStore(url: temp.file("cache-state-\(UUID().uuidString).json"))
    }

    /// Inert migrator: sandboxed defaults pre-marked complete so the live
    /// startup path neither reads real UserDefaults.standard nor probes the
    /// real ~/.claude.json.
    private func makeInertMigrator() -> AutoProfileMigrator {
        let defaults = UserDefaults(suiteName: "kwota-cli-refresh-test-\(UUID())")!
        defaults.set(true, forKey: "autoDetectMigrationCompleted")
        return AutoProfileMigrator(
            profileStore: profileStore,
            oauthRead: { nil },
            defaults: defaults
        )
    }

    private func seedCLIProfile(accessToken: String) throws -> Profile {
        let profile = Profile(name: "CLI", authMethod: .cliSync)
        let cred = Credential.cliToken(
            accessToken: accessToken,
            refreshToken: "r",
            // Comfortable headroom so freshen() is a cheap no-op and the
            // 401 → forceRefresh branch is what the test exercises.
            expiresAt: Date().addingTimeInterval(3600)
        )
        try keychain.write(cred, for: profile.id)
        try profileStore.add(profile)
        try profileStore.setActive(id: profile.id)
        return profile
    }

    // MARK: - Tests

    func test401ThenForceRefreshRotates_RetriesAndAuthenticates() async throws {
        let profile = try seedCLIProfile(accessToken: "old")

        let transport = RecordingTransport(
            rejectTokens: ["old"],
            okHeaders: [
                "anthropic-ratelimit-unified-5h-utilization": "0.4",
                "anthropic-ratelimit-unified-7d-utilization": "0.2"
            ]
        )
        let api = ClaudeAPIClient(transport: { req in transport.handle(req) })

        // CLI keychain has rotated to "new" — reader returns the rotated value.
        let kcJSON = #"""
        {"accessToken":"new","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let refresher = CLITokenRefresher(reader: makeReader(kcJSON), store: keychain)

        let (codexWatcher1, codexCoord1) = makeCodexStubs()
        let vm = MenuBarViewModel(
            usage: makeHermeticUsage(),
            statsStore: makeHermeticStatsStore(),
            cachePersistence: makeHermeticCachePersistence(),
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: api,
            cliRefresher: refresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in }),
            codexAccountWatcher: codexWatcher1,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: makePermissiveCoordinator(),
            codexAutoProfileCoordinator: codexCoord1,
            autoProfileMigrator: makeInertMigrator(),
            activityHistorian: ActivityHistorian(autoBackfill: false),
            historyFileProvider: makeHistoryFileProvider()
        )

        await waitForAuthState(vm, .authenticated)
        await waitForQuiescence({ transport.seenAuthHeaders.count })

        // Wiring assertions — both old and new tokens must have hit the API
        // (proves the 401 → forceRefresh → retry path actually fired the
        // retry with the rotated bearer, not just bounced the same token).
        XCTAssertTrue(
            transport.seenAuthHeaders.contains(where: { $0.contains("old") }),
            "Initial call should have used the old token"
        )
        XCTAssertTrue(
            transport.seenAuthHeaders.contains(where: { $0.contains("new") }),
            "Retry should have used the rotated token"
        )

        // Store now holds the rotated credential so subsequent ticks start
        // from the fresh token (forceRefresh wrote it back).
        let persisted = try keychain.read(for: profile.id)
        guard case .cliToken(let access, _, _)? = persisted else {
            return XCTFail("expected cliToken in store after rotation")
        }
        XCTAssertEqual(access, "new")
    }

    func test401AndCLINotRotated_SkipsRetryAndSurfacesExpired() async throws {
        _ = try seedCLIProfile(accessToken: "stuck")

        let transport = RecordingTransport(rejectTokens: ["stuck"], okHeaders: [:])
        let api = ClaudeAPIClient(transport: { req in transport.handle(req) })

        // CLI keychain still holds the same access token — no rotation.
        // forceRefresh must short-circuit: return nil, do not retry.
        let kcJSON = #"""
        {"accessToken":"stuck","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let refresher = CLITokenRefresher(reader: makeReader(kcJSON), store: keychain)

        let (codexWatcher2, codexCoord2) = makeCodexStubs()
        let vm = MenuBarViewModel(
            usage: makeHermeticUsage(),
            statsStore: makeHermeticStatsStore(),
            cachePersistence: makeHermeticCachePersistence(),
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: api,
            cliRefresher: refresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in }),
            codexAccountWatcher: codexWatcher2,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: makePermissiveCoordinator(),
            codexAutoProfileCoordinator: codexCoord2,
            autoProfileMigrator: makeInertMigrator(),
            activityHistorian: ActivityHistorian(autoBackfill: false),
            historyFileProvider: makeHistoryFileProvider()
        )

        await waitForAuthState(vm, .expired)
        await waitForQuiescence({ transport.seenAuthHeaders.count })

        // Important: every recorded call must have used "stuck". If a retry
        // had fired it would have been "stuck" again — but the refresher's
        // identical-token short-circuit must prevent the second request
        // entirely, so we should never see a clearly-wrong token like "new"
        // and the count of API requests should be one per refresh attempt
        // (not two — no retry).
        XCTAssertTrue(
            transport.seenAuthHeaders.allSatisfy { $0.contains("stuck") },
            "All requests should have carried the stuck token"
        )
        // Each refresh attempt = exactly one API call (no retry). VM init
        // double-fires (subscription + coord.start), so we expect 2 calls
        // total — anything higher means a retry slipped through.
        XCTAssertLessThanOrEqual(
            transport.seenAuthHeaders.count, 2,
            "No retry should have fired when CLI hasn't rotated; got \(transport.seenAuthHeaders.count) calls"
        )
    }

    func test401AndForceRefreshReadFails_SurfacesExpired() async throws {
        _ = try seedCLIProfile(accessToken: "old")

        let transport = RecordingTransport(rejectTokens: ["old"], okHeaders: [:])
        let api = ClaudeAPIClient(transport: { req in transport.handle(req) })

        // Reader has neither file nor keychain probe payload → throws.
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: { nil }
        )
        let refresher = CLITokenRefresher(reader: reader, store: keychain)

        let (codexWatcher3, codexCoord3) = makeCodexStubs()
        let vm = MenuBarViewModel(
            usage: makeHermeticUsage(),
            statsStore: makeHermeticStatsStore(),
            cachePersistence: makeHermeticCachePersistence(),
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: api,
            cliRefresher: refresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in }),
            codexAccountWatcher: codexWatcher3,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: makePermissiveCoordinator(),
            codexAutoProfileCoordinator: codexCoord3,
            autoProfileMigrator: makeInertMigrator(),
            activityHistorian: ActivityHistorian(autoBackfill: false),
            historyFileProvider: makeHistoryFileProvider()
        )

        await waitForAuthState(vm, .expired)
        await waitForQuiescence({ transport.seenAuthHeaders.count })

        // Reader cannot produce a credential, so retry must not fire.
        XCTAssertLessThanOrEqual(
            transport.seenAuthHeaders.count, 2,
            "No retry should fire when forceRefresh's reader fails; got \(transport.seenAuthHeaders.count) calls"
        )
    }

    func test401ThenRetryAlsoFails_SurfacesExpired() async throws {
        _ = try seedCLIProfile(accessToken: "old")

        // Reject every token — second call after rotation also 401's.
        let transport = RecordingTransport(rejectTokens: ["old", "new"], okHeaders: [:])
        let api = ClaudeAPIClient(transport: { req in transport.handle(req) })

        let kcJSON = #"""
        {"accessToken":"new","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let refresher = CLITokenRefresher(reader: makeReader(kcJSON), store: keychain)

        let (codexWatcher4, codexCoord4) = makeCodexStubs()
        let vm = MenuBarViewModel(
            usage: makeHermeticUsage(),
            statsStore: makeHermeticStatsStore(),
            cachePersistence: makeHermeticCachePersistence(),
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: api,
            cliRefresher: refresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in }),
            codexAccountWatcher: codexWatcher4,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: makePermissiveCoordinator(),
            codexAutoProfileCoordinator: codexCoord4,
            autoProfileMigrator: makeInertMigrator(),
            activityHistorian: ActivityHistorian(autoBackfill: false),
            historyFileProvider: makeHistoryFileProvider()
        )

        await waitForAuthState(vm, .expired)
        await waitForQuiescence({ transport.seenAuthHeaders.count })

        // The retry should have fired at least once with "new", confirming
        // the wiring kicked in even though it ultimately failed.
        XCTAssertTrue(
            transport.seenAuthHeaders.contains(where: { $0.contains("new") }),
            "Retry should have used the rotated token even though it also 401'd"
        )
    }

    // Mirror of `testCLIRefresh200CommitsSnapshotToVM` but exercises the
    // exact path the user hit at runtime: VM exists with zero profiles
    // first, then `vm.addProfile(...)` is called — refresh fires through
    // the activeProfileId-sink → rebindHistory → refreshUsageNow chain,
    // which is *different* from the seed-then-init path the other test
    // uses. If this passes but the symptom persists, the bug is in the
    // View layer, not the model.
    func testAddCLIProfileAtRuntimeCommitsSnapshotToVM() async throws {
        let okBody = #"""
        {
          "five_hour": { "utilization": 77, "resets_at": "2099-01-01T00:00:00Z" },
          "seven_day": { "utilization": 50, "resets_at": "2099-01-01T00:00:00Z" }
        }
        """#

        let api = ClaudeAPIClient(transport: { req in
            let url = req.url ?? URL(string: "x://test")!
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(okBody.utf8), resp)
        })

        let kcJSON = #"""
        {"accessToken":"ok","refreshToken":"r","expiresAt":"2099-01-01T00:00:00Z"}
        """#
        let refresher = CLITokenRefresher(reader: makeReader(kcJSON), store: keychain)

        // VM starts EMPTY — same as a fresh-install user opening the app.
        let (codexWatcher5, codexCoord5) = makeCodexStubs()
        let vm = MenuBarViewModel(
            usage: makeHermeticUsage(),
            statsStore: makeHermeticStatsStore(),
            cachePersistence: makeHermeticCachePersistence(),
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: api,
            cliRefresher: refresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in }),
            codexAccountWatcher: codexWatcher5,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: makePermissiveCoordinator(),
            codexAutoProfileCoordinator: codexCoord5,
            autoProfileMigrator: makeInertMigrator(),
            activityHistorian: ActivityHistorian(autoBackfill: false),
            historyFileProvider: makeHistoryFileProvider()
        )
        XCTAssertTrue(vm.hasNoProfiles)
        XCTAssertNil(vm.snapshot)

        // Simulate the user flow: AddProfileSheet → addFromCLI →
        // vm.addProfile(...). The credential value here doesn't have to
        // match the keychain probe; the test transport accepts any token.
        let cred = Credential.cliToken(
            accessToken: "ok",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600)
        )
        try vm.addProfile(name: "Hau", credential: cred, authMethod: .cliSync)

        // Wait for refresh to settle — same gate the other test uses.
        await waitForAuthState(vm, .authenticated)

        XCTAssertNotNil(vm.snapshot,
                        "regression: spinner stuck after Add CLI profile — vm.snapshot must commit through the rebindHistory→refreshUsageNow path")
        XCTAssertEqual(vm.snapshot?.fiveHour.utilization, 77)
        XCTAssertFalse(vm.isSwitchingProfile)
        XCTAssertFalse(vm.showLoadingPlaceholder)
    }

    // Regression: spinner stuck on Add CLI profile.
    // Reproduces the exact scenario the user reported: a freshly-added
    // CLI profile, transport returns 200 with valid usage JSON. After
    // refresh settles, vm.snapshot MUST be non-nil and authState MUST be
    // .authenticated — otherwise UsageTabView's loading-placeholder
    // branch keeps the "Refreshing…" spinner up indefinitely.
    func testCLIRefresh200CommitsSnapshotToVM() async throws {
        _ = try seedCLIProfile(accessToken: "ok")

        // Real OAuth-usage payload shape: top-level five_hour, seven_day,
        // plus the per-model and extra_usage blocks the decoder accepts.
        let okBody = #"""
        {
          "five_hour": { "utilization": 42, "resets_at": "2099-01-01T00:00:00Z" },
          "seven_day": { "utilization": 30, "resets_at": "2099-01-01T00:00:00Z" },
          "seven_day_opus": { "utilization": 0, "resets_at": "2099-01-01T00:00:00Z" },
          "seven_day_sonnet": { "utilization": 13, "resets_at": "2099-01-01T00:00:00Z" },
          "seven_day_omelette": { "utilization": 8, "resets_at": "2099-01-01T00:00:00Z" }
        }
        """#

        let api = ClaudeAPIClient(transport: { req in
            let url = req.url ?? URL(string: "x://test")!
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(okBody.utf8), resp)
        })

        let kcJSON = #"""
        {"accessToken":"ok","refreshToken":"r","expiresAt":"2099-01-01T00:00:00Z"}
        """#
        let refresher = CLITokenRefresher(reader: makeReader(kcJSON), store: keychain)

        let (codexWatcher6, codexCoord6) = makeCodexStubs()
        let vm = MenuBarViewModel(
            usage: makeHermeticUsage(),
            statsStore: makeHermeticStatsStore(),
            cachePersistence: makeHermeticCachePersistence(),
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: api,
            cliRefresher: refresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in }),
            codexAccountWatcher: codexWatcher6,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: makePermissiveCoordinator(),
            codexAutoProfileCoordinator: codexCoord6,
            autoProfileMigrator: makeInertMigrator(),
            activityHistorian: ActivityHistorian(autoBackfill: false),
            historyFileProvider: makeHistoryFileProvider()
        )

        await waitForAuthState(vm, .authenticated)

        XCTAssertNotNil(vm.snapshot,
                        "vm.snapshot must be set after a successful refresh — otherwise UsageTabView's loading placeholder will not release and the user is stuck on a forever spinner")
        XCTAssertEqual(vm.snapshot?.fiveHour.utilization, 42)
        XCTAssertFalse(vm.isSwitchingProfile,
                       "isSwitchingProfile must clear so showLoadingPlaceholder evaluates against snapshot rather than the switch flag")
        XCTAssertFalse(vm.showLoadingPlaceholder,
                       "with a successful refresh, the placeholder gate must release")
    }

    func testMissingCredentialClearsUsageLoadingPlaceholder() async throws {
        let profile = Profile(name: "CLI", authMethod: .cliSync)
        try profileStore.add(profile)
        try profileStore.setActive(id: profile.id)

        let api = ClaudeAPIClient(transport: { _ in
            XCTFail("missing credential must short-circuit before transport")
            fatalError()
        })
        let refresher = CLITokenRefresher(reader: makeReader(nil), store: keychain)

        let (codexWatcher7, codexCoord7) = makeCodexStubs()
        let vm = MenuBarViewModel(
            usage: makeHermeticUsage(),
            statsStore: makeHermeticStatsStore(),
            cachePersistence: makeHermeticCachePersistence(),
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: api,
            cliRefresher: refresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in }),
            codexAccountWatcher: codexWatcher7,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: makePermissiveCoordinator(),
            codexAutoProfileCoordinator: codexCoord7,
            autoProfileMigrator: makeInertMigrator(),
            activityHistorian: ActivityHistorian(autoBackfill: false),
            historyFileProvider: makeHistoryFileProvider()
        )

        await waitForAuthState(vm, .expired)

        XCTAssertNil(vm.snapshot)
        XCTAssertFalse(vm.isSwitchingProfile)
        XCTAssertFalse(vm.showLoadingPlaceholder,
                       "missing credentials must release the top-level Usage loading placeholder")
    }

    func testMalformedUsageResponseClearsUsageLoadingPlaceholder() async throws {
        _ = try seedCLIProfile(accessToken: "bad-json")

        let api = ClaudeAPIClient(transport: { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("not json".utf8), resp)
        })
        let refresher = CLITokenRefresher(reader: makeReader(nil), store: keychain)

        let (codexWatcher8, codexCoord8) = makeCodexStubs()
        let vm = MenuBarViewModel(
            usage: makeHermeticUsage(),
            statsStore: makeHermeticStatsStore(),
            cachePersistence: makeHermeticCachePersistence(),
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: api,
            cliRefresher: refresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in }),
            codexAccountWatcher: codexWatcher8,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: makePermissiveCoordinator(),
            codexAutoProfileCoordinator: codexCoord8,
            autoProfileMigrator: makeInertMigrator(),
            activityHistorian: ActivityHistorian(autoBackfill: false),
            historyFileProvider: makeHistoryFileProvider()
        )

        await waitForAuthState(vm, .authenticated)

        XCTAssertNil(vm.snapshot)
        XCTAssertFalse(vm.isSwitchingProfile)
        XCTAssertFalse(vm.showLoadingPlaceholder,
                       "failed first refresh with no cached snapshot must not keep the Usage tab stuck on Refreshing")
    }
}
