//
//  MenuBarViewModelActivityForwardingTests.swift
//  KwotaTests
//

import XCTest
import Combine
@testable import Kwota

/// An ActivitySource whose emissions the test drives directly.
@MainActor
final class ControllableActivitySource: ActivitySource {
    let subject = PassthroughSubject<ActivityEvent, Never>()
    var activityPublisher: AnyPublisher<ActivityEvent, Never> { subject.eraseToAnyPublisher() }
    func start() {}
    func stop() {}
    func emit(_ event: ActivityEvent) { subject.send(event) }
}

@MainActor
final class MenuBarViewModelActivityForwardingTests: XCTestCase {
    private var temp: TempDirectory!
    private var keychain: KeychainCredentialStore!
    private var profileStore: ProfileStore!

    private let source = ControllableActivitySource()

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

    private func makeVM() -> MenuBarViewModel {
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
        let antigravityWatcherVM = AntigravityProcessWatcher(detect: { nil })
        let antigravityWatcherCoord = AntigravityProcessWatcher(detect: { nil })
        let antigravityCoordStub = AntigravityAutoProfileCoordinator(
            watcher: antigravityWatcherCoord,
            profileStore: profileStore
        )
        let sandboxedDefaults = UserDefaults(suiteName: "kwota-activity-fwd-test-\(UUID())")!
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
        // These tests emit .fileWrite events that reach AwakeSupervisor, so
        // the whole awake stack is stubbed: a unit test must never raise a
        // REAL IOKit power assertion, post a real notification, or read the
        // real awake config from UserDefaults.standard.
        let awakeDefaults = UserDefaults(suiteName: "kwota-activity-fwd-awake-\(UUID())")!
        return MenuBarViewModel(
            usage: usage,
            caffeine: CaffeinateManager(holder: MockSleepAssertionHolder()),
            cachePersistence: CachePersistenceStore(url: temp.file("cache-state-\(UUID().uuidString).json")),
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: stubClient,
            cliRefresher: stubRefresher,
            activitySource: source,
            battery: FakeBatteryMonitor(),
            awakeNotifier: FakeAwakeNotifier(),
            awakeConfigStore: AwakeConfigStore(defaults: awakeDefaults),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: vmWatcher,
            codexAccountWatcher: codexVMWatcher,
            antigravityProcessWatcher: antigravityWatcherVM,
            autoProfileCoordinator: permissiveCoord,
            codexAutoProfileCoordinator: codexCoordStub,
            antigravityAutoProfileCoordinator: antigravityCoordStub,
            autoProfileMigrator: inertMigrator,
            // Hermetic historian: the fixture runs with the default .live
            // startup mode, under which the VM's default historian persists
            // to the REAL Application Support activity-events.json — the
            // codex/antigravity events these tests emit then reappear as
            // phantom bars on the production app's Awake chart (one pair per
            // `make test` run). autoBackfill off keeps the test from walking
            // the real ~/.claude/projects tree too.
            activityHistorian: ActivityHistorian(autoBackfill: false),
            now: { Date() }
        )
    }

    func test_codexEventForwardedToHistorian() {
        let vm = makeVM()
        let before = vm.activityHistorian.timestamps(for: .codex).count
        source.emit(ActivityEvent(date: Date(), provider: .codex, kind: .agentResponse))
        XCTAssertEqual(vm.activityHistorian.timestamps(for: .codex).count, before + 1)
    }

    func test_claudeEventNotForwardedToOtherStore() {
        let vm = makeVM()
        let before = vm.activityHistorian.timestamps(for: .claude).count
        source.emit(ActivityEvent(date: Date(), provider: .claude, kind: .agentResponse))
        // Claude flows through the UsageMonitor path; the sink must skip it.
        XCTAssertEqual(vm.activityHistorian.timestamps(for: .claude).count, before)
    }

    func test_antigravityEventForwarded() {
        let vm = makeVM()
        let before = vm.activityHistorian.timestamps(for: .antigravity).count
        source.emit(ActivityEvent(date: Date(), provider: .antigravity, kind: .agentResponse))
        XCTAssertEqual(vm.activityHistorian.timestamps(for: .antigravity).count, before + 1)
    }

    func test_fileWriteEventNotForwardedToHistorian() {
        let vm = makeVM()
        let before = vm.activityHistorian.timestamps(for: .codex).count
        source.emit(ActivityEvent(date: Date(), provider: .codex, kind: .fileWrite))
        // .fileWrite drives keep-awake only; the chart must ignore it.
        XCTAssertEqual(vm.activityHistorian.timestamps(for: .codex).count, before)
    }
}
