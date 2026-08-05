//
//  MainActorBlockingIOTests.swift
//  KwotaTests
//
//  The target builds with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so
//  anything not explicitly nonisolated runs on the main actor. A blocking
//  call there can freeze the whole app — on 2026-08-04 an unanswered keychain
//  dialog did exactly that for two hours and keep-awake died with it.
//
//  This scan is file-granular on purpose: no Swift syntax tree, no external
//  tooling, and it still stops what matters, because a new file wanting a
//  blocking API has to add an allowlist line with a reason. Stated limit: a
//  file already listed can gain another blocking call unnoticed, which is why
//  entries name the specific API rather than exempting the whole file.
//

import XCTest

final class MainActorBlockingIOTests: XCTestCase {

    private static let bannedAPIs = [
        "SecItemCopyMatching",
        "SecItemAdd",
        "SecItemUpdate",
        "SecItemDelete",
        "SecKeychainSetUserInteractionAllowed",
        "Data(contentsOf",
        "String(contentsOf",
        "waitUntilExit",
        ".contentsOfDirectory(",
        "sqlite3_open",
        "DispatchSemaphore",
    ]

    /// path relative to Kwota/Kwota → the APIs that file is allowed to use,
    /// each because the call is already off the main actor. Populate from
    /// docs/findings/F-006-main-actor-blocking-io-audit.md.
    private static let allowlist: [String: Set<String>] = [
        "Services/Keychain/KeychainGateway.swift": [
            // The one place allowed to talk to Security.framework; every call
            // runs on its own serial queue.
            "SecItemCopyMatching", "SecItemAdd", "SecItemUpdate", "SecItemDelete",
            "SecKeychainSetUserInteractionAllowed",
        ],
        "Services/UsageMonitor.swift": [
            // tickAsync runs the whole read on a per-instance background queue.
            "Data(contentsOf", ".contentsOfDirectory(",
        ],
        "Services/AI/CodexCLIRunner.swift": [
            // resolveBinary() and the config read inside ask() are both
            // wrapped in OffMain.run; ask() is already async (F-006 fixed).
            "Data(contentsOf", ".contentsOfDirectory(",
        ],
        "Services/Awake/ActivityHistorian.swift": [
            // loadPersisted is now nonisolated static (F-006 fixed);
            // scanClaudeBackfill is also nonisolated static and its sole call
            // site wraps the read in OffMain.run (F-006 already-safe).
            "Data(contentsOf", ".contentsOfDirectory(", "String(contentsOf",
        ],
        "Services/Awake/AwakeSessionLog.swift": [
            // loadSessions(from:) is now nonisolated static (F-006 fixed).
            "Data(contentsOf",
        ],
        "Services/Awake/CodexActivitySource.swift": [
            // defaultCompanionRunning/defaultWALProbe are nonisolated static
            // but invoked synchronously from pollLogsWAL() on the main actor
            // by design: the Codex WAL companion gate decides trust
            // per-burst at the instant a WAL mtime bump is observed, and an
            // await there would reopen the exact race the gate exists to
            // close (F-006 escalated).
            "waitUntilExit", ".contentsOfDirectory(",
        ],
        "Services/Awake/ProviderActivityScanner.swift": [
            // ProviderActivityBackfill enum is now nonisolated (F-006
            // declaration-hygiene fix); scanUntracked's read is only ever
            // invoked from CodexActivitySource/AntigravityActivitySource call
            // sites that already wrap it in OffMain.run (F-006 already-safe).
            "Data(contentsOf", "String(contentsOf",
        ],
        "Services/Awake/WatchdogEvidenceWriter.swift": [
            // FileWatchdogEvidenceWriter is already a nonisolated class
            // (F-006 already-safe).
            "Data(contentsOf",
        ],
        "Services/CLICredentialReader.swift": [
            // The real read (line 95) is wrapped in OffMain.run (Task 2-7,
            // F-006 already-safe); SecItemCopyMatching only appears in
            // comments here, not as a call (F-006 confirmed false positive).
            "Data(contentsOf", "SecItemCopyMatching",
        ],
        "Services/CacheCleaner.swift": [
            // All 3 production call sites (MenuBarViewModel.swift:2462,2980,3076)
            // wrap CacheCleaner(...).scan()/.clean() in OffMain.run (F-006
            // already-safe).
            ".contentsOfDirectory(",
        ],
        "Services/CachePersistenceStore.swift": [
            // Whole class is now nonisolated; its only stored state is an
            // immutable URL + FileManager (F-006 fixed).
            "Data(contentsOf",
        ],
        "Services/ClaudeProbe.swift": [
            // "waitUntilExit" appears only in a doc comment describing the
            // ProcessLauncher fix; the real call lives in ProcessLauncher.swift
            // and this file's launcher.run() invocation is itself wrapped in
            // OffMain.run (F-006 fixed, comment reference not a call).
            "waitUntilExit",
        ],
        "Services/JSONLogReader.swift": [
            // discoverFiles() is reached only through read(), which every
            // caller invokes via StatsStore.readChanged's OffMain.run wrap
            // (F-006 already-safe).
            ".contentsOfDirectory(",
        ],
        "Services/NotificationSettingsStore.swift": [
            // load(from:) is now nonisolated static (F-006 fixed).
            "Data(contentsOf",
        ],
        "Services/OAuthAccountReader.swift": [
            // read() backs CLIAccountWatching.readCurrentIdentity(), a
            // protocol-required synchronous method whose callers
            // (AutoProfileCoordinator's guardRefresh/stillSignedIn) reason
            // explicitly about the read happening synchronously relative to
            // the CLI's on-disk writes; forcing it async reopens that
            // ordering race (F-006 escalated).
            "Data(contentsOf",
        ],
        "Services/Privileged/SystemCacheCleaner.swift": [
            // clearContents(of:) has zero call sites inside the Kwota app
            // target; it only runs in the separate KwotaPrivilegedHelper
            // process, which has no MainActor runtime (F-006 already-safe,
            // different process).
            ".contentsOfDirectory(",
        ],
        "Services/ProcessLauncher.swift": [
            // ProcessLauncher/SystemProcessLauncher are now Sendable; all 3
            // probe call sites wrap launcher.run(...) in OffMain.run (F-006
            // fixed).
            "waitUntilExit",
        ],
        "Services/ProfileStore.swift": [
            // load() runs synchronously inside init() as part of app boot;
            // it also quarantines corrupt files and flips loadedSuccessfully,
            // so making it async ripples into the whole DI/bootstrap chain
            // for a one-shot small local read (F-006 escalated).
            "Data(contentsOf",
        ],
        "Services/Provider/Antigravity/AntigravityOverageReader.swift": [
            // Struct is now nonisolated (was @MainActor); AntigravityProvider.fetchUsage
            // calls readModelCredits() via OffMain.run (F-006 fixed).
            "sqlite3_open",
        ],
        "Services/Provider/Antigravity/AntigravityProcessDetector.swift": [
            // detect() is called synchronously on the main actor by explicit,
            // documented design in AntigravityProcessWatcher.start() so that
            // `current` is set before the first refresh fires; an earlier
            // Task.detached attempt for this exact call silently failed to
            // get scheduled in production for 1h+ (F-006 escalated).
            "waitUntilExit",
        ],
        "Services/Provider/Antigravity/AntigravityProvider.swift": [
            // "sqlite3_open" appears only in a doc comment describing the
            // AntigravityOverageReader fix; the real call lives in that
            // reader and this file's readModelCredits() invocation is itself
            // wrapped in OffMain.run (F-006 fixed, comment reference not a
            // call).
            "sqlite3_open",
        ],
        "Services/Provider/Codex/CodexAuthReader.swift": [
            // read() backs CodexAccountWatcher's sync protocol-required
            // identity read and CodexAutoProfileCoordinator.seedKeychain(),
            // whose handle(_:) must stay synchronous so its dedup latch is
            // set before any suspension; forcing read() async breaks that
            // documented invariant (F-006 escalated).
            "Data(contentsOf",
        ],
        "Services/Stats/AntigravityStatsReader.swift": [
            // Reached only through read()/read(only:), invoked via
            // StatsStore.readChanged's OffMain.run wrap (F-006 already-safe).
            ".contentsOfDirectory(", "sqlite3_open",
        ],
        "Services/Stats/CodexTraceReader.swift": [
            // Same StatsStore.readChanged OffMain.run wrap as
            // AntigravityStatsReader (F-006 already-safe).
            ".contentsOfDirectory(", "sqlite3_open",
        ],
        "Services/Stats/CodexTraceWatcher.swift": [
            // discover() is now async and wrapped in OffMain.run; fire()/the
            // poll loop were updated accordingly (F-006 fixed).
            ".contentsOfDirectory(",
        ],
        "Services/Stats/StatsStore.swift": [
            // loadEnvelope is already nonisolated static (F-006 already-safe).
            "Data(contentsOf",
        ],
        "Services/SwitcherSummaryStore.swift": [
            // Whole class is now nonisolated; its only stored state is an
            // immutable URL (F-006 fixed).
            "Data(contentsOf",
        ],
        "Services/UsageHistoryStore.swift": [
            // ensureLoaded mutates actor-isolated self.entries/self.loaded,
            // so it can't be extracted to a pure nonisolated static like the
            // other stores; reached from MenuBarViewModel.init, the
            // non-async onActiveProfileChange callback (rebindHistory), and
            // loadAntigravityGroupHistory/appendAntigravityGroupHistory —
            // converting ripples through several sync closures (F-006
            // escalated).
            "Data(contentsOf",
        ],
        "ViewModels/MenuBarViewModel.swift": [
            // loadAntigravityGroupHistory reads .contentsOfDirectory( from
            // the same non-async onActiveProfileChange callback path as
            // UsageHistoryStore above (F-006 escalated).
            ".contentsOfDirectory(",
        ],
        "Views/Settings/DataStorage/ProfileHistoryCard.swift": [
            // loadCount was already wrapped in OffMain.run (F-006
            // already-safe); exportHistory is now async and its read is
            // wrapped in OffMain.run too (F-006 fixed).
            "Data(contentsOf",
        ],
    ]

    private func sourceRoot() -> URL {
        // .../Kwota/KwotaTests/MainActorBlockingIOTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KwotaTests
            .deletingLastPathComponent()   // Kwota (project dir)
            .appendingPathComponent("Kwota", isDirectory: true)
    }

    func test_noUnreviewedBlockingAPIsInProductionSources() throws {
        let root = sourceRoot()
        var violations: [String] = []

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )
        XCTAssertNotNil(enumerator, "source root not found at \(root.path)")

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let contents = try String(contentsOf: url, encoding: .utf8)
            let permitted = Self.allowlist[relative] ?? []
            for api in Self.bannedAPIs where contents.contains(api) {
                if permitted.contains(api) { continue }
                violations.append("\(relative): \(api)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Blocking APIs found outside the allowlist:
            \(violations.sorted().joined(separator: "\n"))

            Either move the call off the main actor (see OffMain.run), or add an
            allowlist entry in this file naming the API and why it is safe.
            """
        )
    }
}
