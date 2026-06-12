//
//  MenuBarViewModelCacheCleanErrorTests.swift
//  KwotaTests
//

import XCTest
import ServiceManagement
@testable import Kwota

@MainActor
final class MenuBarViewModelCacheCleanErrorTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    /// Build a VM with hermetic stubs so construction does no live IO.
    /// Mirrors the stub set used by MenuBarViewModelProfilesTests.makeVM.
    /// `helper` injects a privileged-helper manager (e.g. an enabled fake)
    /// for the system-clean tests; nil falls back to the inert `.live()` one.
    private func makeVM(helper: PrivilegedHelperManager? = nil) -> MenuBarViewModel {
        let keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let dataRoot = temp.url
        let store = ProfileStore(
            profilesFile: temp.file("profiles.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in dataRoot.appendingPathComponent(id.uuidString) }
        )
        let api = ClaudeAPIClient(transport: { _ in
            let resp = HTTPURLResponse(url: URL(string: "x://test")!,
                                        statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        })
        let watcher = CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in })
        let coordinator = AutoProfileCoordinator(
            watcher: watcher, profileStore: store, alwaysAllowRefresh: true)
        let codexWatcherStub = CodexAccountWatcher(authRead: { nil }, fileEvents: AsyncStream { _ in })
        let codexCoordStub = CodexAutoProfileCoordinator(
            watcher: codexWatcherStub, profileStore: store, keychain: keychain, clock: { Date() })
        let usage = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: temp.file("ledger-\(UUID().uuidString).json"),
            dailyCounterURL: temp.file("daily-counter-\(UUID().uuidString).json")
        )
        return MenuBarViewModel(
            usage: usage,
            cachePersistence: CachePersistenceStore(url: temp.file("cache-state.json")),
            profileStore: store,
            credentialStore: keychain,
            apiClient: api,
            privilegedHelper: helper,
            activitySource: CompositeActivitySource(sources: []),
            codexAccountWatcher: codexWatcherStub,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: coordinator,
            codexAutoProfileCoordinator: codexCoordStub
        )
    }

    /// An enabled privileged-helper manager whose clean returns `result`.
    /// Uses the same fakes as PrivilegedHelperManagerTests (shared test target).
    private func enabledHelper(
        cleanResult: Result<SystemCleanOutcome, PrivilegedHelperError>
    ) async -> PrivilegedHelperManager {
        let connector = FakeHelperConnector(version: KwotaHelperInfo.version)
        connector.cleanResult = cleanResult
        let manager = PrivilegedHelperManager(
            service: FakeSystemService(status: .enabled), connector: connector)
        await manager.refreshStatus()   // status → .enabled
        return manager
    }

    /// One auto-on system-cache row (icon services) so a clean routes through
    /// the privileged helper rather than CacheCleaner.
    private func systemRow() -> CachePathRow {
        let entry = SystemCacheCatalog.entries[0]
        return CachePathRow(
            displayName: entry.displayName,
            path: URL(fileURLWithPath: entry.path),
            sizeBytes: 1, risk: .safe,
            autoCleanEnabled: true, isSystem: true)
    }

    /// Background auto-clean (`surfaceErrors: false`) that FAILS stays silent —
    /// it only logs. It must NOT wipe a banner from a prior manual failure, or
    /// the user loses the only signal that privileged cleaning is broken.
    func test_backgroundAutoCleanFailure_keepsSurfacedSystemError() async {
        let helper = await enabledHelper(cleanResult: .failure(.cleanFailed("boom")))
        let vm = makeVM(helper: helper)
        vm.cacheState.rows = [systemRow()]
        vm.cacheState.systemCleanError = .connectionFailed("prior manual failure")

        await vm.cacheClean(targets: [systemRow().path], surfaceErrors: false)

        XCTAssertEqual(
            vm.cacheState.systemCleanError, .connectionFailed("prior manual failure"),
            "a failed background auto-clean must not erase a surfaced failure banner")
    }

    /// Background auto-clean that SUCCEEDS genuinely resolves the problem, so it
    /// SHOULD clear a stale banner even though it never surfaces errors.
    func test_backgroundAutoCleanSuccess_clearsSurfacedSystemError() async {
        let helper = await enabledHelper(
            cleanResult: .success(SystemCleanOutcome(itemsRemoved: 2, bytesFreed: 99)))
        let vm = makeVM(helper: helper)
        vm.cacheState.rows = [systemRow()]
        vm.cacheState.systemCleanError = .connectionFailed("prior failure, now resolved")

        await vm.cacheClean(targets: [systemRow().path], surfaceErrors: false)

        XCTAssertNil(
            vm.cacheState.systemCleanError,
            "a successful background auto-clean must clear the now-stale banner")
    }

    /// A user-initiated clean that SUCCEEDS clears the stale banner.
    func test_userInitiatedClean_clearsSurfacedSystemError() async {
        let helper = await enabledHelper(
            cleanResult: .success(SystemCleanOutcome(itemsRemoved: 1, bytesFreed: 1)))
        let vm = makeVM(helper: helper)
        vm.cacheState.rows = [systemRow()]
        vm.cacheState.systemCleanError = .connectionFailed("prior false timeout")

        await vm.cacheClean(targets: [systemRow().path], surfaceErrors: true)

        XCTAssertNil(
            vm.cacheState.systemCleanError,
            "a user-initiated clean must clear the stale banner at the start")
    }

    /// Cleaning an unrelated NORMAL cache must not erase a standing
    /// system-cache error — the two categories are independent signals.
    func test_cleaningNormalCache_keepsSystemError() async {
        let vm = makeVM()
        vm.cacheState.settings.deletePermanently = true   // avoid touching the real Trash
        let dir = temp.url.appendingPathComponent("npm-cache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("blob").path, contents: Data([0, 1, 2]))
        vm.cacheState.rows = [
            CachePathRow(displayName: "npm", path: dir, sizeBytes: 3, risk: .safe,
                         autoCleanEnabled: true, isSystem: false)
        ]
        vm.cacheState.systemCleanError = .connectionFailed("system still broken")

        await vm.cacheClean(targets: [dir], surfaceErrors: true)

        XCTAssertEqual(
            vm.cacheState.systemCleanError, .connectionFailed("system still broken"),
            "cleaning a normal cache must not erase an unrelated system-cache error")
    }
}
