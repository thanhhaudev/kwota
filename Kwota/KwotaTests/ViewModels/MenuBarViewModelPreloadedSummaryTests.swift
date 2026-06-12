//
//  MenuBarViewModelPreloadedSummaryTests.swift
//  KwotaTests
//
//  ProfileSwitcherCard's switch flow captures the coordinator-cached
//  ProviderUsageSummary for the to-be-active profile and hands it to
//  vm.adoptPreloadedSummary(_:) right after setActive. This eliminates
//  the "Refreshing…" flash on Codex switches whose lastSnapshot is
//  always nil (UsageSnapshot is Claude-specific). These tests pin the
//  guard direction (providerID match) and the side effect on
//  isSwitchingProfile.
//

import XCTest
@testable import Kwota

@MainActor
final class MenuBarViewModelPreloadedSummaryTests: XCTestCase {
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

    private func makeVM(activeProviderID: ProviderID) throws -> MenuBarViewModel {
        let profile = Profile(
            id: UUID(),
            name: "user@x.com",
            authMethod: .cliSync,
            providerID: activeProviderID,
            email: "user@x.com"
        )
        try profileStore.add(profile)
        try profileStore.setActive(id: profile.id)

        // Two separate Claude watcher instances are required (mirrors the
        // pattern in MenuBarViewModelRefreshGateTests.makeVM):
        //   - vmWatcher  → passed to VM; onChange never wired by the VM, so
        //     the synchronous nil-emit on start() goes nowhere.
        //   - coordWatcher → inside the coordinator; onChange is wired there
        //     but start() is never called on it, so no emit reaches handle().
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
        // Two separate Codex watcher instances for the same reason: the VM
        // calls codexAccountWatcher.start() which emits nil synchronously via
        // recompute(). If the same watcher instance is shared with the
        // CodexAutoProfileCoordinator (which wires onChange in start()),
        // that nil emit fires handle(nil) → archives the Codex profile →
        // clears activeProfileId, breaking the providerID guard in
        // adoptPreloadedSummary. Separate instances break the feedback loop.
        let codexVMWatcher = CodexAccountWatcher(
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
        let sandboxedDefaults = UserDefaults(suiteName: "kwota-preload-test-\(UUID())")!
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
        return MenuBarViewModel(
            usage: usage,
            cachePersistence: CachePersistenceStore(url: temp.file("cache-state-\(UUID().uuidString).json")),
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: stubClient,
            cliRefresher: stubRefresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: vmWatcher,
            codexAccountWatcher: codexVMWatcher,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: permissiveCoord,
            codexAutoProfileCoordinator: codexCoordStub,
            autoProfileMigrator: inertMigrator,
            activityHistorian: ActivityHistorian(autoBackfill: false),
            now: { Date() }
        )
    }

    private func makeSummary(_ providerID: ProviderID) -> ProviderUsageSummary {
        ProviderUsageSummary(
            providerID: providerID,
            fetchedAt: Date(),
            primary: UsageBucket(utilization: 12, resetsAt: nil),
            secondary: UsageBucket(utilization: 34, resetsAt: nil),
            payload: UsageSnapshot.zeroes()
        )
    }

    func test_adoptPreloadedSummary_setsSummary_whenProviderMatches() throws {
        let vm = try makeVM(activeProviderID: .codex)
        let codexSummary = makeSummary(.codex)
        vm.adoptPreloadedSummary(codexSummary)
        XCTAssertEqual(vm.summary?.providerID, .codex)
        XCTAssertEqual(vm.summary?.primary?.utilization, 12)
        XCTAssertEqual(vm.summary?.secondary?.utilization, 34)
    }

    func test_adoptPreloadedSummary_clearsIsSwitchingProfile_whenProviderMatches() throws {
        let vm = try makeVM(activeProviderID: .codex)
        // Codex switch always enters isSwitchingProfile = true (no UsageSnapshot
        // cache for Codex). Adopting a preloaded summary should flip it back.
        XCTAssertTrue(vm.isSwitchingProfile, "precondition: Codex switch sets isSwitchingProfile=true")
        vm.adoptPreloadedSummary(makeSummary(.codex))
        XCTAssertFalse(vm.isSwitchingProfile)
    }

    func test_adoptPreloadedSummary_ignoredWhenProviderIDMismatch() throws {
        // Active profile is Codex; an in-flight Claude summary (e.g. from a
        // raced refresh of the previous active) must not be adopted under
        // the new profile — that would mis-attribute usage.
        let vm = try makeVM(activeProviderID: .codex)
        let switchingBefore = vm.isSwitchingProfile
        let summaryBefore = vm.summary
        vm.adoptPreloadedSummary(makeSummary(.claude))
        XCTAssertEqual(vm.summary?.providerID, summaryBefore?.providerID,
                       "summary must not be overwritten by a wrong-provider preload")
        XCTAssertEqual(vm.isSwitchingProfile, switchingBefore,
                       "isSwitchingProfile must not be cleared by a wrong-provider preload")
    }
}
