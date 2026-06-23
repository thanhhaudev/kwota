//
//  MenuBarViewModelLiveRecorderTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

@MainActor
final class MenuBarViewModelLiveRecorderTests: XCTestCase {

    private final class SpyRecorder: LiveAccountRecording {
        var receivedProfiles: [Profile]?
        var receivedActiveID: UUID?
        func recordNonActive(
            profiles: [Profile],
            currentActiveID: @escaping () -> UUID?,
            backoffUntil: (ProviderID) -> Date?
        ) async {
            receivedProfiles = profiles
            receivedActiveID = currentActiveID()
        }
    }

    private final class GatedSpyRecorder: LiveAccountRecording {
        private(set) var callCount = 0
        private var gate = Gate()

        final class Gate {
            private var continuation: CheckedContinuation<Void, Never>?
            private var released = false
            private var enteredContinuation: CheckedContinuation<Void, Never>?
            private var entered = false

            func wait() async {
                entered = true
                enteredContinuation?.resume()
                enteredContinuation = nil
                if released { return }
                await withCheckedContinuation { c in self.continuation = c }
            }

            func release() {
                released = true
                continuation?.resume()
                continuation = nil
            }

            func waitUntilEntered() async {
                if entered { return }
                await withCheckedContinuation { c in self.enteredContinuation = c }
            }
        }

        func waitUntilEntered() async { await gate.waitUntilEntered() }
        func release() { gate.release() }

        private var finishedContinuation: CheckedContinuation<Void, Never>?
        private var finished = false

        func waitUntilFinished() async {
            if finished { return }
            await withCheckedContinuation { c in self.finishedContinuation = c }
        }

        func recordNonActive(
            profiles: [Profile],
            currentActiveID: @escaping () -> UUID?,
            backoffUntil: (ProviderID) -> Date?
        ) async {
            callCount += 1
            await gate.wait()
            finished = true
            finishedContinuation?.resume()
            finishedContinuation = nil
        }
    }

    func test_launchLiveRecordingIfIdle_skipsWhileInFlight() async {
        let spy = GatedSpyRecorder()
        let vm = MenuBarViewModelLiveRecorderFixture.make(recorder: spy)

        vm.launchLiveRecordingIfIdle()       // run 1 starts, blocks in recordNonActive
        await spy.waitUntilEntered()
        vm.launchLiveRecordingIfIdle()       // must be skipped — prior run in flight

        spy.release()                        // let run 1 finish
        await spy.waitUntilFinished()

        XCTAssertEqual(spy.callCount, 1)
    }

    func test_recordLiveNonActiveAccounts_forwardsProfilesAndActiveID() async {
        let spy = SpyRecorder()
        let vm = MenuBarViewModelLiveRecorderFixture.make(recorder: spy)
        let activeId = vm.profileStore.activeProfileId

        await vm.recordLiveNonActiveAccounts()

        XCTAssertEqual(spy.receivedProfiles?.map(\.id), vm.profileStore.profiles.map(\.id))
        XCTAssertEqual(spy.receivedActiveID, activeId)
    }
}

// MARK: - Fixture

/// Hermetic MenuBarViewModel factory for LiveAccountRecorder wiring tests.
/// Copied from MenuBarViewModelRefreshProfileTests.makeVM and extended with
/// the `liveAccountRecorder:` injection point.
@MainActor
enum MenuBarViewModelLiveRecorderFixture {

    static func make(recorder: any LiveAccountRecording) -> MenuBarViewModel {
        let keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let temp = TempDirectory()
        let dataRoot = temp.url
        let store = ProfileStore(
            profilesFile: temp.file("profiles.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in dataRoot.appendingPathComponent(id.uuidString) }
        )
        // Seed one active profile so activeProfileId is non-nil.
        let profile = Profile(name: "Test", authMethod: .cliSync)
        try? store.add(profile)

        let vmWatcher = CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in })
        let coordWatcher = CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in })
        let permissiveCoord = AutoProfileCoordinator(
            watcher: coordWatcher,
            profileStore: store,
            alwaysAllowRefresh: true
        )
        let codexWatcherStub = CodexAccountWatcher(authRead: { nil }, fileEvents: AsyncStream { _ in })
        let codexCoordWatcher = CodexAccountWatcher(authRead: { nil }, fileEvents: AsyncStream { _ in })
        let codexCoordStub = CodexAutoProfileCoordinator(
            watcher: codexCoordWatcher,
            profileStore: store,
            keychain: keychain,
            clock: { Date() }
        )
        let antigravityWatcherVM = AntigravityProcessWatcher(detect: { nil })
        let antigravityWatcherCoord = AntigravityProcessWatcher(detect: { nil })
        let antigravityCoordStub = AntigravityAutoProfileCoordinator(
            watcher: antigravityWatcherCoord,
            profileStore: store
        )
        let sandboxedDefaults = UserDefaults(suiteName: "kwota-live-recorder-test-\(UUID())")!
        sandboxedDefaults.set(true, forKey: "autoDetectMigrationCompleted")
        let inertMigrator = AutoProfileMigrator(
            profileStore: store,
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
            apiClient: stubClient,
            cliRefresher: stubRefresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: vmWatcher,
            codexAccountWatcher: codexWatcherStub,
            antigravityProcessWatcher: antigravityWatcherVM,
            autoProfileCoordinator: permissiveCoord,
            codexAutoProfileCoordinator: codexCoordStub,
            antigravityAutoProfileCoordinator: antigravityCoordStub,
            autoProfileMigrator: inertMigrator,
            activityHistorian: ActivityHistorian(autoBackfill: false),
            historyFileProvider: { id in temp.file("history-\(id.uuidString).json") },
            liveAccountRecorder: recorder
        )
    }
}
