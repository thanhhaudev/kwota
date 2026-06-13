//
//  MenuBarViewModelProfilesTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class MenuBarViewModelProfilesTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    private func makeVM() -> MenuBarViewModel {
        let keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let dataRoot = temp.url
        let store = ProfileStore(
            profilesFile: temp.file("profiles.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in dataRoot.appendingPathComponent(id.uuidString) }
        )
        // Stubbed API client — never hits the network during tests.
        let api = ClaudeAPIClient(transport: { _ in
            let resp = HTTPURLResponse(url: URL(string: "x://test")!,
                                        statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        })
        let watcher = CLIAccountWatcher(
            oauthRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let coordinator = AutoProfileCoordinator(
            watcher: watcher,
            profileStore: store,
            alwaysAllowRefresh: true
        )
        let codexWatcherStub = CodexAccountWatcher(
            authRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let codexCoordStub = CodexAutoProfileCoordinator(
            watcher: codexWatcherStub,
            profileStore: store,
            keychain: keychain,
            clock: { Date() }
        )
        // Hermetic UsageMonitor: prevents the live default from reading
        // ~/.claude/projects/**/*.jsonl and writing to
        // ~/Library/Application Support/com.thanhhaudev.Kwota/ledger.json
        // during parallel test runs.
        let usage = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: temp.file("ledger-\(UUID().uuidString).json"),
            dailyCounterURL: temp.file("daily-counter-\(UUID().uuidString).json")
        )
        // Inert migrator: sandboxed defaults pre-marked complete so the live
        // startup path neither reads real UserDefaults.standard nor probes
        // the real ~/.claude.json.
        let sandboxedDefaults = UserDefaults(suiteName: "kwota-profiles-test-\(UUID())")!
        sandboxedDefaults.set(true, forKey: "autoDetectMigrationCompleted")
        let inertMigrator = AutoProfileMigrator(
            profileStore: store,
            oauthRead: { nil },
            defaults: sandboxedDefaults
        )
        // Stub refresher: reader points at a missing temp file with a nil
        // keychain probe so forceRefresh never touches Claude Code's real
        // Keychain item (cross-app consent prompt) or ~/.claude/.credentials.json.
        let stubRefresher = CLITokenRefresher(
            reader: CLICredentialReader(
                credentialsFile: temp.file("missing-credentials.json"),
                keychainProbe: { nil }
            ),
            store: keychain
        )
        return MenuBarViewModel(
            usage: usage,
            statsStore: makeHermeticStatsStore(),
            cachePersistence: CachePersistenceStore(url: temp.file("cache-state-\(UUID().uuidString).json")),
            profileStore: store,
            credentialStore: keychain,
            apiClient: api,
            cliRefresher: stubRefresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in }),
            codexAccountWatcher: codexWatcherStub,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: coordinator,
            codexAutoProfileCoordinator: codexCoordStub,
            autoProfileMigrator: inertMigrator,
            activityHistorian: ActivityHistorian(autoBackfill: false)
        )
    }

    func testAddingProfileSwitchesActiveAndRebindsHistory() async throws {
        let vm = makeVM()

        XCTAssertTrue(vm.profileStore.profiles.isEmpty)
        XCTAssertNil(vm.profileStore.activeProfileId)

        try vm.addProfile(name: "P1", credential: .sessionKey(value: "k1"), authMethod: .sessionKey)
        XCTAssertEqual(vm.profileStore.profiles.map(\.name), ["P1"])
        XCTAssertEqual(vm.profileStore.activeProfileId, vm.profileStore.profiles[0].id)

        try vm.addProfile(name: "P2", credential: .sessionKey(value: "k2"), authMethod: .sessionKey)
        XCTAssertEqual(vm.profileStore.profiles.map(\.name), ["P1", "P2"])
        // After add, P2 becomes active (addProfile calls setActive on the new one).
        XCTAssertEqual(vm.profileStore.activeProfileId, vm.profileStore.profiles[1].id)
    }

    func testRemovingActiveProfileAdvancesAndPersists() async throws {
        let vm = makeVM()
        try vm.addProfile(name: "P1", credential: .sessionKey(value: "k1"), authMethod: .sessionKey)
        try vm.addProfile(name: "P2", credential: .sessionKey(value: "k2"), authMethod: .sessionKey)
        let p2id = vm.profileStore.activeProfileId!

        try vm.profileStore.remove(id: p2id)
        XCTAssertEqual(vm.profileStore.profiles.map(\.name), ["P1"])
        XCTAssertEqual(vm.profileStore.activeProfileId, vm.profileStore.profiles[0].id)
    }

    // Regression: after the bundle-id rename stranded existing profiles, the
    // app launched with zero profiles and `UsageTabView.showLoadingPlaceholder`
    // returned true forever (snapshot == nil with no fetcher to clear it),
    // burying the Add-Profile entry point behind a permanent spinner. The
    // loader gate must release in the no-profile state so the empty-state
    // view can render.
    func testShowLoadingPlaceholder_falseWhenNoProfiles() {
        let vm = makeVM()

        XCTAssertTrue(vm.profileStore.profiles.isEmpty)
        XCTAssertNil(vm.profileStore.activeProfileId)
        XCTAssertNil(vm.snapshot)
        XCTAssertTrue(vm.hasNoProfiles)
        XCTAssertFalse(vm.showLoadingPlaceholder)
    }

    // Regression: Codex profiles never populate `vm.snapshot` (that field
    // is the Claude-only persisted UsageSnapshot). The earlier loader gate
    // checked `snapshot == nil && authState == .refreshing`, which was true
    // every time `popoverDidOpen()` fired refresh — even when `summary` was
    // populated from a prior successful fetch. The popover then flashed the
    // spinner over otherwise-good Codex data on every reopen. Loader must
    // release when EITHER snapshot or summary is non-nil.
    func testShowLoadingPlaceholder_falseWhenSummaryPopulatedAndRefreshing() async throws {
        let vm = makeVM()
        try vm.addProfile(name: "P1", credential: .sessionKey(value: "k1"), authMethod: .sessionKey)

        // Wait for the auto-refresh kicked by addProfile to settle so
        // isSwitchingProfile clears (stubbed transport returns 401 → .expired).
        await waitUntil(timeout: 3.0) { !vm.isSwitchingProfile }

        // Simulate the post-first-fetch state: prior summary lives in memory,
        // Claude's snapshot stays nil (this is the Codex profile shape), and
        // a follow-up refresh has flipped authState to .refreshing.
        vm.summary = ProviderUsageSummary(
            providerID: .codex,
            fetchedAt: Date(),
            primary: nil,
            secondary: nil,
            payload: CodexUsageSnapshot()
        )
        vm.authState = .refreshing

        XCTAssertNil(vm.snapshot, "Codex shape: snapshot is the Claude-only cache, expected nil here")
        XCTAssertFalse(
            vm.showLoadingPlaceholder,
            "Loader must not eat the chart when summary already has Codex data"
        )
    }

    func testShowLoadingPlaceholder_trueWhenBothCachesEmptyAndRefreshing() async throws {
        let vm = makeVM()
        try vm.addProfile(name: "P1", credential: .sessionKey(value: "k1"), authMethod: .sessionKey)

        await waitUntil(timeout: 3.0) { !vm.isSwitchingProfile }

        vm.summary = nil
        vm.authState = .refreshing

        XCTAssertNil(vm.snapshot)
        XCTAssertTrue(
            vm.showLoadingPlaceholder,
            "First-ever fetch: nothing cached, refresh in flight → loader is correct"
        )
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
    }

    // MARK: - Snapshot commit gate (race fix)
    //
    // Regression: after adding the first profile, the spinner stayed for
    // a long time until the user toggled the popover. Root cause: the
    // strict generation gate dropped a Task's valid result whenever an
    // opportunistic trigger (popoverDidOpen, coord tick) bumped
    // `refreshGeneration` while the Task was awaiting the network. The
    // freshness-based `canCommitSnapshot` gate fixes this by accepting any
    // valid data when nothing is displayed yet, and otherwise picking the
    // newer `fetchedAt`.

    private func snap(_ utilization: Double, _ at: Date) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageBucket(utilization: utilization, resetsAt: nil),
            sevenDay: UsageBucket(utilization: utilization, resetsAt: nil),
            fetchedAt: at
        )
    }

    func testCanCommitSnapshot_acceptsAnyDataWhenNothingDisplayed() async throws {
        let vm = makeVM()
        try vm.addProfile(name: "P1", credential: .sessionKey(value: "k"), authMethod: .sessionKey)
        let id = vm.profileStore.activeProfileId!

        // Brand-new profile with no committed snapshot → any fetch wins.
        // (The vm.snapshot may still be nil here even after an in-flight
        // refresh because the test transport returns 401, but that only
        // strengthens the precondition.)
        XCTAssertNil(vm.snapshot)
        XCTAssertTrue(vm.canCommitSnapshot(snap(50, Date()), forProfileId: id),
                      "first valid result for a profile with no displayed data must commit, even when generation has been bumped by a concurrent trigger")
    }

    func testCanCommitSnapshot_rejectsWrongProfile() {
        let vm = makeVM()
        let foreignId = UUID()
        XCTAssertFalse(vm.canCommitSnapshot(snap(0, Date()), forProfileId: foreignId),
                       "a Task's result must never commit when its profile is no longer active")
    }

    func test_adoptPreloadedSummary_recordsLastSummaryByProfile() throws {
        let vm = makeVM()
        let p = Profile(id: UUID(), name: "a@x.com", authMethod: .cliSync,
                        providerID: .claude, email: "a@x.com")
        try vm.profileStore.add(p)
        try vm.profileStore.setActive(id: p.id)

        let s = ProviderUsageSummary(
            providerID: .claude,
            fetchedAt: Date(timeIntervalSince1970: 4242),
            primary: nil, secondary: nil,
            payload: EmptyPayload(), retryAfter: nil
        )
        vm.adoptPreloadedSummary(s)

        XCTAssertEqual(vm.lastSummaryByProfile[p.id]?.fetchedAt, s.fetchedAt)
    }
}
