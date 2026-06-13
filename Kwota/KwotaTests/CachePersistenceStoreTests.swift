//
//  CachePersistenceStoreTests.swift
//  KwotaTests
//
//  Round-trip + corruption-recovery coverage for the Cache-tab
//  persistence layer. The VM-level hydration logic is covered separately
//  via integration on `MenuBarViewModel`.
//

import XCTest
@testable import Kwota

final class CachePersistenceStoreTests: XCTestCase {

    func testLoadReturnsInitialWhenFileMissing() {
        let tmp = TempDirectory()
        let store = CachePersistenceStore(url: tmp.file("missing.json"))
        XCTAssertEqual(store.load(), .initial)
    }

    func testSaveThenLoadRoundTripsEverySection() {
        let tmp = TempDirectory()
        let target = tmp.file("cache-state.json")
        let store = CachePersistenceStore(url: target)

        let state = CachePersistedState(
            settings: AutoCleanSettings(
                isEnabled: false,
                scanInterval: .fourHours,
                globalCapBytes: 80_000_000_000,
                aiLanguage: .vietnamese,
                autoEmptyTrashAfterDays: 7,
                deletePermanently: true
            ),
            aiModel: .haiku,
            aiEvaluationsByPath: [
                "/tmp/yarn": CacheAIEvaluation(
                    safety: .safe,
                    warning: nil,
                    purpose: "Yarn package cache",
                    detail: "Re-downloads on install.",
                    modelUsed: "claude-sonnet-4-6",
                    evaluatedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ],
            customPaths: [
                .init(urlPath: "/Users/x/.custom-cache", displayName: "My cache")
            ],
            autoCleanByPath: [
                "/tmp/yarn": true,
                "/Users/x/.custom-cache": false
            ],
            riskyAlertedPaths: ["/tmp/risky"],
            sizesByPath: [
                "/tmp/yarn": 1_234_567_890,
                "/Users/x/.custom-cache": 42
            ],
            trashedItems: [
                .init(
                    originalPath: "/Users/x/Library/Caches/Yarn",
                    trashedURLPath: "/Users/x/.Trash/Yarn",
                    trashedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ]
        )

        store.save(state)
        let loaded = store.load()
        XCTAssertEqual(loaded, state)
    }

    func testLoadHandlesPreSizesByPathFiles() throws {
        // JSON shape from before `sizesByPath` was added — `sizesByPath`
        // key absent. Custom `init(from:)` defaults the field to [:]
        // instead of failing the whole decode (which would wipe the user's
        // settings + evaluations on upgrade).
        let tmp = TempDirectory()
        let target = tmp.file("cache-state.json")
        let legacy = """
        {
          "settings": {"isEnabled": true, "scanInterval": "thirtyMinutes", "globalCapBytes": 60000000000, "aiLanguage": "en"},
          "aiModel": "claude-sonnet-4-6",
          "aiEvaluationsByPath": {},
          "customPaths": [],
          "autoCleanByPath": {"/tmp/x": true},
          "riskyAlertedPaths": []
        }
        """
        try Data(legacy.utf8).write(to: target)
        let store = CachePersistenceStore(url: target)
        let loaded = store.load()
        XCTAssertEqual(loaded.autoCleanByPath, ["/tmp/x": true])
        XCTAssertEqual(loaded.sizesByPath, [:],
                       "missing sizesByPath should default to empty, not crash")
        XCTAssertEqual(loaded.trashedItems, [],
                       "missing trashedItems should default to empty, not crash")
        XCTAssertEqual(loaded.settings.autoEmptyTrashAfterDays, 0,
                       "missing autoEmptyTrashAfterDays should default to 0 (off)")
        XCTAssertFalse(loaded.settings.deletePermanently,
                       "missing deletePermanently should default to false — inheriting permanent-delete silently would be unsafe")
    }

    func testRoundTripsRemovedDefaultPathsAndSystemCustomPath() {
        let tmp = TempDirectory()
        let store = CachePersistenceStore(url: tmp.file("cache-state.json"))

        var state = CachePersistedState.initial
        state.removedDefaultPaths = ["/Users/x/Library/Caches/Yarn"]
        state.customPaths = [
            .init(urlPath: "/Users/x/.custom-cache", displayName: "My cache", isSystem: false),
            .init(urlPath: "/Library/Caches/com.example.thing", displayName: "Example", isSystem: true)
        ]

        store.save(state)
        let loaded = store.load()
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.removedDefaultPaths, ["/Users/x/Library/Caches/Yarn"])
        XCTAssertEqual(loaded.customPaths.first(where: { $0.isSystem })?.displayName, "Example")
    }

    func testLoadDefaultsNewFieldsOnLegacyFile() throws {
        // A blob written before removedDefaultPaths / CustomPath.isSystem existed.
        let tmp = TempDirectory()
        let target = tmp.file("cache-state.json")
        let legacy = """
        {
          "settings": {"isEnabled": true, "scanInterval": "thirtyMinutes", "globalCapBytes": 60000000000, "aiLanguage": "en"},
          "aiModel": "claude-sonnet-4-6",
          "aiEvaluationsByPath": {},
          "customPaths": [{"urlPath": "/Users/x/.c", "displayName": "C"}],
          "autoCleanByPath": {},
          "riskyAlertedPaths": [],
          "sizesByPath": {},
          "trashedItems": []
        }
        """
        try Data(legacy.utf8).write(to: target)
        let loaded = CachePersistenceStore(url: target).load()
        XCTAssertEqual(loaded.removedDefaultPaths, [],
                       "missing removedDefaultPaths should default to empty, not crash")
        XCTAssertEqual(loaded.customPaths.first?.isSystem, false,
                       "missing CustomPath.isSystem should default to false")
    }

    func testLoadDefaultsEngineFieldsOnLegacyFile() throws {
        // A blob written before aiEngine / aiCodexModel existed. Decode
        // must default to Claude + codex-default instead of failing the
        // whole decode (which would wipe settings + evaluations).
        let tmp = TempDirectory()
        let target = tmp.file("cache-state.json")
        let legacy = """
        {
          "settings": {"isEnabled": true, "scanInterval": "thirtyMinutes", "globalCapBytes": 60000000000, "aiLanguage": "en"},
          "aiModel": "claude-sonnet-4-6",
          "aiEvaluationsByPath": {},
          "customPaths": [],
          "autoCleanByPath": {},
          "riskyAlertedPaths": [],
          "sizesByPath": {},
          "trashedItems": []
        }
        """
        try Data(legacy.utf8).write(to: target)
        let loaded = CachePersistenceStore(url: target).load()
        XCTAssertEqual(loaded.aiEngine, .claude,
                       "missing aiEngine should default to Claude")
        XCTAssertEqual(loaded.aiCodexModel, .codexDefault,
                       "missing aiCodexModel should default to codexDefault")
        XCTAssertEqual(loaded.aiModel, .sonnet,
                       "legacy aiModel maps to the sonnet tier")
    }

    func testRoundTripsEngineAndCodexModel() {
        let tmp = TempDirectory()
        let store = CachePersistenceStore(url: tmp.file("cache-state.json"))

        var state = CachePersistedState.initial
        state.aiEngine = .codex
        state.aiCodexModel = .gpt54Mini

        store.save(state)
        let loaded = store.load()
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.aiEngine, .codex)
        XCTAssertEqual(loaded.aiCodexModel, .gpt54Mini)
    }

    func testLoadDefaultsCodexModelWhenOnlyEnginePresent() throws {
        // Partial-upgrade blob: an intermediate build wrote aiEngine but
        // not aiCodexModel. The missing field must fall back to default,
        // not fail the decode.
        let tmp = TempDirectory()
        let target = tmp.file("cache-state.json")
        let blob = """
        {
          "settings": {"isEnabled": true, "scanInterval": "thirtyMinutes", "globalCapBytes": 60000000000, "aiLanguage": "en"},
          "aiModel": "claude-sonnet-4-6",
          "aiEngine": "codex",
          "aiEvaluationsByPath": {},
          "customPaths": [],
          "autoCleanByPath": {},
          "riskyAlertedPaths": [],
          "sizesByPath": {},
          "trashedItems": []
        }
        """
        try Data(blob.utf8).write(to: target)
        let loaded = CachePersistenceStore(url: target).load()
        XCTAssertEqual(loaded.aiEngine, .codex,
                       "present aiEngine should decode")
        XCTAssertEqual(loaded.aiCodexModel, .codexDefault,
                       "absent aiCodexModel should fall back to default")
    }

    func testLoadFallsBackToDefaultsOnUnrecognizedEnumRawValues() throws {
        // A newer build wrote enum cases this binary doesn't know. The
        // try?-with-default decode must swallow the unknown rawValue and
        // fall back rather than wiping the whole persisted state.
        let tmp = TempDirectory()
        let target = tmp.file("cache-state.json")
        let blob = """
        {
          "settings": {"isEnabled": true, "scanInterval": "thirtyMinutes", "globalCapBytes": 60000000000, "aiLanguage": "en"},
          "aiModel": "claude-sonnet-4-6",
          "aiEngine": "gemini",
          "aiCodexModel": "gpt-99-turbo",
          "aiEvaluationsByPath": {},
          "customPaths": [],
          "autoCleanByPath": {},
          "riskyAlertedPaths": [],
          "sizesByPath": {},
          "trashedItems": []
        }
        """
        try Data(blob.utf8).write(to: target)
        let loaded = CachePersistenceStore(url: target).load()
        XCTAssertEqual(loaded.aiEngine, .claude,
                       "unrecognized aiEngine rawValue should fall back to default")
        XCTAssertEqual(loaded.aiCodexModel, .codexDefault,
                       "unrecognized aiCodexModel rawValue should fall back to default")
        XCTAssertEqual(loaded.aiModel, .sonnet,
                       "legacy aiModel maps to the sonnet tier")
    }

    func testRoundTripsAntigravityModel() {
        let tmp = TempDirectory()
        let store = CachePersistenceStore(url: tmp.file("cache-state.json"))
        var state = CachePersistedState.initial
        state.aiAntigravityModel = .gemini35FlashLow
        store.save(state)
        let loaded = store.load()
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.aiAntigravityModel, .gemini35FlashLow)
    }

    func testLoadDefaultsAntigravityModelOnLegacyFile() throws {
        let tmp = TempDirectory()
        let target = tmp.file("cache-state.json")
        let legacy = """
        {
          "settings": {"isEnabled": true, "scanInterval": "thirtyMinutes", "globalCapBytes": 60000000000, "aiLanguage": "en"},
          "aiModel": "haiku", "aiEngine": "antigravity",
          "aiEvaluationsByPath": {}, "customPaths": [], "autoCleanByPath": {},
          "riskyAlertedPaths": [], "sizesByPath": {}, "trashedItems": []
        }
        """
        try Data(legacy.utf8).write(to: target)
        let loaded = CachePersistenceStore(url: target).load()
        XCTAssertEqual(loaded.aiAntigravityModel, .agyDefault,
                       "missing aiAntigravityModel should default to agyDefault")
    }

    func testLoadReturnsInitialOnGarbageFile() throws {
        let tmp = TempDirectory()
        let target = tmp.file("cache-state.json")
        try Data("not even close to json".utf8).write(to: target)
        let store = CachePersistenceStore(url: target)

        // Corrupt file → fall back to initial; the cache tab is a
        // convenience surface, partial state would be worse than fresh.
        XCTAssertEqual(store.load(), .initial)
    }

    func testWithBuilderMutatesOnlyTheNamedField() {
        let original = AutoCleanSettings.stubDefault
        let flipped = original.with(isEnabled: false)
        XCTAssertFalse(flipped.isEnabled)
        XCTAssertEqual(flipped.scanInterval, original.scanInterval)
        XCTAssertEqual(flipped.globalCapBytes, original.globalCapBytes)
        XCTAssertEqual(flipped.aiLanguage, original.aiLanguage)
        XCTAssertEqual(flipped.autoEmptyTrashAfterDays, original.autoEmptyTrashAfterDays)
        XCTAssertEqual(flipped.deletePermanently, original.deletePermanently)

        let permanent = original.with(deletePermanently: true)
        XCTAssertTrue(permanent.deletePermanently)
        XCTAssertEqual(permanent.isEnabled, original.isEnabled)

        let multi = original.with(globalCapBytes: 100_000_000_000, autoEmptyTrashAfterDays: 14)
        XCTAssertEqual(multi.globalCapBytes, 100_000_000_000)
        XCTAssertEqual(multi.autoEmptyTrashAfterDays, 14)
        XCTAssertEqual(multi.isEnabled, original.isEnabled)
    }

    func testSaveDoesNotLeaveTempFileBehind() {
        let tmp = TempDirectory()
        let target = tmp.file("cache-state.json")
        let store = CachePersistenceStore(url: target)

        store.save(.initial)
        store.save(.initial)  // overwrite path exercises replaceItemAt

        let tmpSibling = target.appendingPathExtension("tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpSibling.path),
                       "temp file should be replaced, not orphaned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
}
