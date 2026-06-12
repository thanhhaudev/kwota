//
//  SystemCacheRowsTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class SystemCacheRowsTests: XCTestCase {

    func testDefaultRowsIncludeOneSystemRowPerCatalogEntry() {
        let systemRows = CacheStubData.defaultRows().filter { $0.isSystem }
        XCTAssertEqual(systemRows.count, SystemCacheCatalog.entries.count)
    }

    func testSystemRowMatchesItsCatalogEntry() {
        let row = CacheStubData.defaultRows().first { $0.isSystem }
        XCTAssertNotNil(row)
        XCTAssertEqual(
            SystemCacheCatalog.identifier(for: row!.path),
            "iconservices")
        XCTAssertEqual(row?.displayName, "Icon services cache")
    }

    func testSystemRowsShipWithAutoCleanOffAndAreNotCustom() {
        for row in CacheStubData.defaultRows() where row.isSystem {
            XCTAssertFalse(row.autoCleanEnabled,
                           "system rows must ship auto-clean OFF — user opts in")
            XCTAssertFalse(row.isCustom)
        }
    }

    func testNonSystemRowsAreUnmarked() {
        let xcodeRow = CacheStubData.defaultRows().first { $0.displayName == "Xcode DerivedData" }
        XCTAssertNotNil(xcodeRow)
        XCTAssertFalse(xcodeRow!.isSystem)
    }

    // MARK: - scopeCollisionNames

    /// The icon-services cache ships as both a user row and a system row with
    /// the same name, so the default set must flag exactly that name.
    func testScopeCollisionNamesFlagsTheSharedIconCacheName() {
        let collisions = CachePathRow.scopeCollisionNames(in: CacheStubData.defaultRows())
        XCTAssertEqual(collisions, ["Icon services cache"])
    }

    /// A name carried only by a system row (no user twin) is not a collision —
    /// the system pill alone disambiguates it, so no `user` pill is wanted.
    func testScopeCollisionNamesIgnoresSystemOnlyName() {
        let rows = [
            makeRow("Icon services cache", isSystem: true),
            makeRow("Xcode DerivedData", isSystem: false)
        ]
        XCTAssertTrue(CachePathRow.scopeCollisionNames(in: rows).isEmpty)
    }

    private func makeRow(_ name: String, isSystem: Bool, isCustom: Bool = false) -> CachePathRow {
        CachePathRow(
            displayName: name,
            path: URL(fileURLWithPath: "/tmp/\(name)"),
            sizeBytes: 0,
            risk: .safe,
            autoCleanEnabled: false,
            isCustom: isCustom,
            isSystem: isSystem)
    }

    // MARK: - isCleanable

    func testCatalogSystemRowIsCleanable() {
        // isSystem && !isCustom — the built-in catalog cache, cleaned via the helper.
        XCTAssertTrue(makeRow("Icon services cache", isSystem: true, isCustom: false).isCleanable)
    }

    func testCustomRowIsCleanable() {
        // !isSystem && isCustom — a user folder inside $HOME, cleaned via CacheCleaner.
        XCTAssertTrue(makeRow("My cache", isSystem: false, isCustom: true).isCleanable)
    }

    func testDefaultRowIsCleanable() {
        XCTAssertTrue(makeRow("Xcode DerivedData", isSystem: false, isCustom: false).isCleanable)
    }

    func testUserAddedSystemRowIsNotCleanable() {
        // isSystem && isCustom — a user-added system path: tracking-only, no clean.
        XCTAssertFalse(makeRow("Some system cache", isSystem: true, isCustom: true).isCleanable)
    }

    func testClassifyAddPathHomeItselfIsCustom() {
        let home = URL(fileURLWithPath: "/Users/alice")
        XCTAssertEqual(MenuBarViewModel.classifyAddPath(home, home: home), .custom)
    }

    func testClassifyAddPathSiblingOfHomeIsUnsupported() {
        // `/Users/aliceEvil` shares the `/Users/alice` string prefix but is not
        // under home and isn't cache-like → rejected, not trackable.
        let home = URL(fileURLWithPath: "/Users/alice")
        let sibling = URL(fileURLWithPath: "/Users/aliceEvil/cache")
        if case .unsupported = MenuBarViewModel.classifyAddPath(sibling, home: home) {
            // expected
        } else {
            XCTFail("sibling-of-home non-cache path must be .unsupported")
        }
    }

    func testClassifyAddPathBroadRootsAreUnsupported() {
        let home = URL(fileURLWithPath: "/Users/alice")
        for p in ["/", "/Users", "/Library", "/Applications", "/Volumes/Ext/data"] {
            let kind = MenuBarViewModel.classifyAddPath(URL(fileURLWithPath: p), home: home)
            if case .unsupported = kind { continue }
            XCTFail("\(p) must be .unsupported, got \(kind)")
        }
    }

    func testClassifyAddPathCacheLikeOutsideHomeIsSystemTracking() {
        let home = URL(fileURLWithPath: "/Users/alice")
        XCTAssertEqual(
            MenuBarViewModel.classifyAddPath(
                URL(fileURLWithPath: "/Library/Caches/com.example.other"), home: home),
            .systemTracking)
        XCTAssertEqual(
            MenuBarViewModel.classifyAddPath(
                URL(fileURLWithPath: "/private/var/folders/ab/xy/C/com.example"), home: home),
            .systemTracking)
    }

    func testIsCacheLikeSystemPath() {
        XCTAssertTrue(MenuBarViewModel.isCacheLikeSystemPath(URL(fileURLWithPath: "/Library/Caches/x")))
        XCTAssertTrue(MenuBarViewModel.isCacheLikeSystemPath(URL(fileURLWithPath: "/private/var/folders/a/b/C")))
        XCTAssertFalse(MenuBarViewModel.isCacheLikeSystemPath(URL(fileURLWithPath: "/Users/bob/Documents")))
        XCTAssertFalse(MenuBarViewModel.isCacheLikeSystemPath(URL(fileURLWithPath: "/Library")))
    }

    // MARK: - splitCleanTargets

    func testSplitCleanTargetsSeparatesSystemFromNormal() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let normal = home.appendingPathComponent("Library/Caches/Yarn")
        let system = URL(fileURLWithPath: "/Library/Caches/com.apple.iconservices.store")

        let split = MenuBarViewModel.splitCleanTargets([normal, system])

        XCTAssertEqual(split.normal, [normal])
        XCTAssertEqual(split.system, ["iconservices"])
    }

    func testSplitCleanTargetsHandlesAllNormal() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let a = home.appendingPathComponent(".npm/_cacache")
        let split = MenuBarViewModel.splitCleanTargets([a])
        XCTAssertEqual(split.normal, [a])
        XCTAssertTrue(split.system.isEmpty)
    }

    // MARK: - bulkEvaluationCandidates

    func testBulkEvaluationCandidatesIncludeSystemRows() {
        // System rows (e.g. the built-in Icon services cache) are now
        // first-class for AI evaluation — the model judges them from the
        // path like any other, so "Evaluate all" no longer skips them.
        let rows = CacheStubData.defaultRows()
        XCTAssertTrue(rows.contains { $0.isSystem }, "precondition: a system row exists")
        let candidates = MenuBarViewModel.bulkEvaluationCandidates(from: rows)
        XCTAssertTrue(candidates.contains { $0.isSystem },
                      "a system row must be a bulk-evaluation candidate")
        XCTAssertEqual(candidates.count, rows.count,
                       "every row is a candidate — nothing is filtered out")
    }

    func testBulkEvaluationCandidatesIncludeAlreadyEvaluatedNonSystemRows() {
        // Force re-evaluate semantics: "Evaluate all" re-runs every non-system
        // row, including ones that already carry an evaluation — mirroring the
        // single-row force-overwrite. Without this, batch silently becomes a
        // permanent no-op once every row has been evaluated once.
        var rows = CacheStubData.defaultRows()
        let idx = rows.firstIndex { $0.displayName == "Xcode DerivedData" }!
        XCTAssertFalse(rows[idx].isSystem, "precondition: target row is non-system")
        rows[idx].aiEvaluation = CacheAIEvaluation(
            safety: .safe, warning: nil, purpose: "x", detail: nil,
            modelUsed: "m", evaluatedAt: Date())
        let candidates = MenuBarViewModel.bulkEvaluationCandidates(from: rows)
        XCTAssertTrue(candidates.contains { $0.id == rows[idx].id })
    }

    // MARK: - cacheEvalNotificationContent

    func testBulkSuccessNotificationPluralizesCount() {
        let one = MenuBarViewModel.cacheEvalNotificationContent(.bulkSuccess(count: 1))
        XCTAssertEqual(one.title, "Cache evaluation complete")
        XCTAssertEqual(one.body, "Analyzed 1 cache.")
        XCTAssertEqual(one.identifier, "kwota.cache.eval.bulk")

        let many = MenuBarViewModel.cacheEvalNotificationContent(.bulkSuccess(count: 5))
        XCTAssertEqual(many.body, "Analyzed 5 caches.")
        XCTAssertEqual(many.identifier, "kwota.cache.eval.bulk")
    }

    func testBulkFailureNotificationSharesBulkIdentifier() {
        let fail = MenuBarViewModel.cacheEvalNotificationContent(.bulkFailure)
        XCTAssertEqual(fail.title, "Cache evaluation failed")
        XCTAssertEqual(fail.body, "Couldn't finish — open Kwota to retry.")
        // Same identifier as success so a retry replaces the prior banner.
        XCTAssertEqual(fail.identifier, "kwota.cache.eval.bulk")
    }

    func testRowNotificationIdentifierIsKeyedByRowID() {
        let a = UUID(), b = UUID()
        let okA = MenuBarViewModel.cacheEvalNotificationContent(.rowSuccess(rowID: a, name: "Yarn"))
        let okB = MenuBarViewModel.cacheEvalNotificationContent(.rowSuccess(rowID: b, name: "pnpm"))
        XCTAssertEqual(okA.body, "Evaluated 'Yarn'.")
        XCTAssertEqual(okA.identifier, "kwota.cache.eval.row.\(a.uuidString)")
        // Distinct rows get distinct identifiers so concurrent evals coexist.
        XCTAssertNotEqual(okA.identifier, okB.identifier)

        let failA = MenuBarViewModel.cacheEvalNotificationContent(.rowFailure(rowID: a, name: "Yarn"))
        XCTAssertEqual(failA.title, "Cache evaluation failed")
        XCTAssertEqual(failA.body, "Couldn't evaluate 'Yarn' — open Kwota to retry.")
        // Success and failure for the same row collapse to one banner.
        XCTAssertEqual(failA.identifier, okA.identifier)
    }

    // MARK: - seedRows / hiddenBuiltInRows tombstone filter

    func testSeedRowsDropsTombstonedDefaultByPath() {
        let iconUser = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.apple.iconservices.store").path
        let seeded = MenuBarViewModel.seedRows(removingTombstoned: [iconUser])
        XCTAssertFalse(seeded.contains { $0.path.path == iconUser })
        XCTAssertTrue(seeded.contains { $0.displayName == "Xcode DerivedData" },
                      "only the tombstoned path is dropped")
    }

    func testHiddenBuiltInRowsReturnsOnlyTombstonedSeeds() {
        let yarn = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Yarn").path
        let hidden = MenuBarViewModel.hiddenBuiltInRows(removed: [yarn])
        XCTAssertEqual(hidden.map(\.path.path), [yarn])
    }

    func testHiddenBuiltInRowsIgnoresUnknownPath() {
        let hidden = MenuBarViewModel.hiddenBuiltInRows(removed: ["/nope/not/seeded"])
        XCTAssertTrue(hidden.isEmpty)
    }

    // MARK: - classifyAddPath

    func testClassifyAddPathInsideHomeIsCustom() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent("Projects/build-cache")
        XCTAssertEqual(MenuBarViewModel.classifyAddPath(url, home: home), .custom)
    }

    func testClassifyAddPathOutsideHomeIsSystemTracking() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = URL(fileURLWithPath: "/Library/Caches/com.example.other")
        XCTAssertEqual(MenuBarViewModel.classifyAddPath(url, home: home), .systemTracking)
    }

    func testClassifyAddPathCatalogPathIsRestore() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = URL(fileURLWithPath: "/Library/Caches/com.apple.iconservices.store")
        XCTAssertEqual(
            MenuBarViewModel.classifyAddPath(url, home: home),
            .catalogRestore(path: "/Library/Caches/com.apple.iconservices.store"))
    }

    // MARK: - chooseAutoCleanTargets excludes tracking-only rows

    func testChooseAutoCleanTargetsExcludesUserAddedSystemRow() {
        var userSystem = makeRow("Tracking only", isSystem: true, isCustom: true)
        userSystem.sizeBytes = 5_000_000_000
        userSystem.autoCleanEnabled = true   // even if somehow on, it must be skipped
        var normal = makeRow("Yarn", isSystem: false, isCustom: true)
        normal.sizeBytes = 1_000_000_000
        normal.autoCleanEnabled = true

        let picked = MenuBarViewModel.chooseAutoCleanTargets(
            from: [userSystem, normal], byteOverage: 100)

        XCTAssertEqual(picked, [normal.path],
                       "a tracking-only (isSystem && isCustom) row is never an auto-clean target")
    }

    // MARK: - isHelperManaged

    func testIsHelperManagedTrueForCatalogRow() {
        let catalog = makeCatalogRow()
        XCTAssertTrue(catalog.isHelperManaged,
                      "a row at a SystemCacheCatalog path is sized/cleaned by the helper")
    }

    func testIsHelperManagedFalseForNonCatalogRows() {
        // isSystem alone is not enough — user-added system-scope rows are
        // sized by the unprivileged walk and keep working on ad-hoc builds.
        XCTAssertFalse(makeRow("Tracking only", isSystem: true, isCustom: true).isHelperManaged)
        XCTAssertFalse(makeRow("Yarn", isSystem: false, isCustom: true).isHelperManaged)
    }

    // MARK: - chooseAutoCleanTargets vs helper-managed rows (ad-hoc builds)

    func testChooseAutoCleanTargetsDropsHelperManagedWhenUnsupported() {
        var catalog = makeCatalogRow()
        catalog.sizeBytes = 5_000_000_000
        catalog.autoCleanEnabled = true
        var normal = makeRow("Yarn", isSystem: false, isCustom: true)
        normal.sizeBytes = 1_000_000_000
        normal.autoCleanEnabled = true

        let picked = MenuBarViewModel.chooseAutoCleanTargets(
            from: [catalog, normal], byteOverage: 100, includeHelperManaged: false)

        XCTAssertEqual(picked, [normal.path],
                       "on an ad-hoc build the helper can never clean a catalog row — auto-clean must not retry it")
    }

    func testChooseAutoCleanTargetsKeepsHelperManagedByDefault() {
        var catalog = makeCatalogRow()
        catalog.sizeBytes = 5_000_000_000
        catalog.autoCleanEnabled = true

        let picked = MenuBarViewModel.chooseAutoCleanTargets(
            from: [catalog], byteOverage: 100)

        XCTAssertEqual(picked, [catalog.path],
                       "signed builds keep routing catalog rows to the helper")
    }

    /// A row at a real `SystemCacheCatalog` path (`isSystem && !isCustom`),
    /// matching how `CacheStubData.systemRows()` seeds it.
    private func makeCatalogRow() -> CachePathRow {
        CachePathRow(
            displayName: "Icon services cache",
            path: URL(fileURLWithPath: "/Library/Caches/com.apple.iconservices.store"),
            sizeBytes: 0,
            risk: .safe,
            autoCleanEnabled: false,
            isCustom: false,
            isSystem: true)
    }

    // MARK: - autoCleanMap

    func testAutoCleanMapToleratesDuplicatePaths() {
        var a = makeRow("Dup", isSystem: false, isCustom: false)
        a.autoCleanEnabled = false
        var b = makeRow("Dup", isSystem: false, isCustom: true)  // same path "/tmp/Dup"
        b.autoCleanEnabled = true

        // Must NOT trap; last value wins.
        let map = MenuBarViewModel.autoCleanMap(from: [a, b])
        XCTAssertEqual(map["/tmp/Dup"], true)
        XCTAssertEqual(map.count, 1)
    }
}
