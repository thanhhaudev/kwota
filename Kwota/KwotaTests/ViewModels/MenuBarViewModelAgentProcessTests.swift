//
//  MenuBarViewModelAgentProcessTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

/// Serves a queue of ps results; repeats the last one when exhausted.
final class StubPSRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<ProcessResult, Error>]
    init(_ results: [Result<ProcessResult, Error>]) {
        precondition(!results.isEmpty)
        self.queue = results
    }
    func next() throws -> ProcessResult {
        lock.lock(); defer { lock.unlock() }
        let result = queue.count > 1 ? queue.removeFirst() : queue[0]
        return try result.get()
    }
    static func ok(_ stdout: String) -> Result<ProcessResult, Error> {
        .success(ProcessResult(stdout: stdout, stderr: "", exitCode: 0))
    }
}

@MainActor
final class RecordingKiller: AgentProcessKilling {
    var result: AgentProcessKillResult = .terminated
    private(set) var killedPIDs: [Int32] = []
    func terminate(pid: Int32) -> AgentProcessKillResult {
        killedPIDs.append(pid)
        return result
    }
}

@MainActor
final class MenuBarViewModelAgentProcessTests: XCTestCase {
    private var temp: TempDirectory!
    private var keychain: KeychainCredentialStore!
    private var profileStore: ProfileStore!

    private let psOrphanAndLive = """
      4821     1   0.2 02:13:45 ??       /opt/homebrew/bin/codex app-server
      9210   812   1.4    22:11 ttys016  /Users/hau/.claude/local/claude --resume abc
    """
    private let psOrphanOnly = """
      4821     1   0.2 02:13:45 ??       /opt/homebrew/bin/codex app-server
    """
    private let psLiveOnly = """
      9210   812   1.4    22:11 ttys016  /Users/hau/.claude/local/claude --resume abc
    """

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

    private func makeVM(ps: StubPSRunner, killer: RecordingKiller) -> MenuBarViewModel {
        let vmWatcher = CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in })
        let coordWatcher = CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in })
        let permissiveCoord = AutoProfileCoordinator(
            watcher: coordWatcher, profileStore: profileStore, alwaysAllowRefresh: true)
        let codexVMWatcher = CodexAccountWatcher(authRead: { nil }, fileEvents: AsyncStream { _ in })
        let codexCoordWatcher = CodexAccountWatcher(authRead: { nil }, fileEvents: AsyncStream { _ in })
        let codexCoordStub = CodexAutoProfileCoordinator(
            watcher: codexCoordWatcher, profileStore: profileStore,
            keychain: keychain, clock: { Date() })
        let antigravityWatcherVM = AntigravityProcessWatcher(detect: { nil })
        let antigravityWatcherCoord = AntigravityProcessWatcher(detect: { nil })
        let antigravityCoordStub = AntigravityAutoProfileCoordinator(
            watcher: antigravityWatcherCoord, profileStore: profileStore)
        let sandboxedDefaults = UserDefaults(suiteName: "kwota-agent-proc-test-\(UUID())")!
        sandboxedDefaults.set(true, forKey: "autoDetectMigrationCompleted")
        let inertMigrator = AutoProfileMigrator(
            profileStore: profileStore, oauthRead: { nil }, defaults: sandboxedDefaults)
        let usage = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: temp.file("ledger-\(UUID().uuidString).json"),
            dailyCounterURL: temp.file("daily-counter-\(UUID().uuidString).json"))
        let stubClient = ClaudeAPIClient(transport: { req in
            let url = req.url ?? URL(string: "https://example.invalid")!
            let resp = HTTPURLResponse(url: url, statusCode: 401,
                                       httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        })
        let vm = MenuBarViewModel(
            usage: usage,
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: stubClient,
            // Reuses ControllableActivitySource from
            // MenuBarViewModelActivityForwardingTests.swift (same test module) —
            // keeps the fixture hermetic; the live default would watch real dirs.
            activitySource: ControllableActivitySource(),
            cliAccountWatcher: vmWatcher,
            codexAccountWatcher: codexVMWatcher,
            antigravityProcessWatcher: antigravityWatcherVM,
            autoProfileCoordinator: permissiveCoord,
            codexAutoProfileCoordinator: codexCoordStub,
            antigravityAutoProfileCoordinator: antigravityCoordStub,
            autoProfileMigrator: inertMigrator,
            agentProcessScanner: AgentProcessScanner(
                runPS: { try ps.next() },
                // Stubbed so the test never spawns a real lsof.
                runCWD: { _ in ProcessResult(stdout: "", stderr: "", exitCode: 1) },
                selfPID: 99999),
            agentProcessKiller: killer,
            now: { Date() }
        )
        vm.agentProcessRescanDelayNanos = 0
        return vm
    }

    // MARK: - Scanning

    func test_scanNow_populatesOrphansFirst() async {
        let vm = makeVM(ps: StubPSRunner([StubPSRunner.ok(psOrphanAndLive)]), killer: RecordingKiller())
        await vm.scanAgentProcessesNow()
        XCTAssertEqual(vm.agentProcesses.map(\.pid), [4821, 9210]) // orphan sorted first
        XCTAssertTrue(vm.agentProcesses[0].isOrphan)
    }

    func test_scanFailure_keepsPreviousSnapshot() async {
        struct Boom: Error {}
        let ps = StubPSRunner([StubPSRunner.ok(psOrphanAndLive), .failure(Boom())])
        let vm = makeVM(ps: ps, killer: RecordingKiller())
        await vm.scanAgentProcessesNow()
        XCTAssertEqual(vm.agentProcesses.count, 2)
        await vm.scanAgentProcessesNow() // ps throws this time
        XCTAssertEqual(vm.agentProcesses.count, 2, "nil scan must not blank the list")
    }

    // MARK: - Polling lifecycle

    func test_startPolling_isIdempotent_andStopEnds() async {
        let vm = makeVM(ps: StubPSRunner([StubPSRunner.ok(psOrphanAndLive)]), killer: RecordingKiller())
        vm.startAgentProcessPolling()
        vm.startAgentProcessPolling()
        XCTAssertTrue(vm.isAgentProcessPollingActive)
        // First scan lands asynchronously; poll for it.
        for _ in 0..<200 where vm.agentProcesses.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.agentProcesses.count, 2)
        vm.stopAgentProcessPolling()
        XCTAssertFalse(vm.isAgentProcessPollingActive)
    }

    // MARK: - Kill flow

    func test_killOrphan_killsAndRescans() async {
        let ps = StubPSRunner([StubPSRunner.ok(psOrphanAndLive), StubPSRunner.ok(psLiveOnly)])
        let killer = RecordingKiller()
        let vm = makeVM(ps: ps, killer: killer)
        await vm.scanAgentProcessesNow()
        await vm.killAgentProcess(pid: 4821)
        XCTAssertEqual(killer.killedPIDs, [4821])
        XCTAssertEqual(vm.agentProcesses.map(\.pid), [9210], "rescan removed the killed row")
        XCTAssertNil(vm.agentProcessKillNotice)
    }

    func test_killOrphan_survivor_setsNotice() async {
        // Same ps output before and after the kill — process refused SIGTERM.
        let ps = StubPSRunner([StubPSRunner.ok(psOrphanAndLive)])
        let vm = makeVM(ps: ps, killer: RecordingKiller())
        await vm.scanAgentProcessesNow()
        await vm.killAgentProcess(pid: 4821)
        XCTAssertNotNil(vm.agentProcessKillNotice)
        XCTAssertTrue(vm.agentProcessKillNotice?.contains("did not exit") == true)
    }

    func test_killOrphan_permissionDenied_setsNotice() async {
        let killer = RecordingKiller()
        killer.result = .permissionDenied
        let vm = makeVM(ps: StubPSRunner([StubPSRunner.ok(psOrphanAndLive)]), killer: killer)
        await vm.scanAgentProcessesNow()
        await vm.killAgentProcess(pid: 4821)
        XCTAssertTrue(vm.agentProcessKillNotice?.contains("Permission denied") == true)
    }

    func test_kill_liveProcessAllowed() async {
        // Editors (e.g. Zed Agent Panel) keep live-ppid sessions running
        // after their window closes, so any listed row is killable; the
        // UI confirmation alert is the safety gate, not an isOrphan guard.
        let ps = StubPSRunner([StubPSRunner.ok(psOrphanAndLive), StubPSRunner.ok(psOrphanOnly)])
        let killer = RecordingKiller()
        let vm = makeVM(ps: ps, killer: killer)
        await vm.scanAgentProcessesNow()
        await vm.killAgentProcess(pid: 9210) // live claude, ppid 812
        XCTAssertEqual(killer.killedPIDs, [9210])
        XCTAssertEqual(vm.agentProcesses.map(\.pid), [4821])
    }
}
