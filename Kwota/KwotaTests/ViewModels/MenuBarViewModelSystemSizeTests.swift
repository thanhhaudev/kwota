//
//  MenuBarViewModelSystemSizeTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class MenuBarViewModelSystemSizeTests: XCTestCase {
    func test_applyingSystemSizes_patchesMatchingSystemRow() {
        let entry = SystemCacheCatalog.entries[0]   // iconservices
        let rows = [
            CachePathRow(displayName: "Normal",
                         path: URL(fileURLWithPath: "/tmp/x"),
                         sizeBytes: 10, risk: .safe,
                         autoCleanEnabled: false, isSystem: false),
            CachePathRow(displayName: entry.displayName,
                         path: URL(fileURLWithPath: entry.path),
                         sizeBytes: 0, risk: .safe,
                         autoCleanEnabled: false, isSystem: true)
        ]
        let out = MenuBarViewModel.applyingSystemSizes(rows, sizes: [entry.identifier: 4096])
        XCTAssertEqual(out[0].sizeBytes, 10, "normal row untouched")
        XCTAssertEqual(out[1].sizeBytes, 4096, "system row patched from daemon size")
        XCTAssertTrue(out[1].exists)
    }

    // MARK: - applyingScanEntries (unprivileged walk must not size system rows)

    /// The unprivileged `CacheCleaner` walk can't read root-only catalog system
    /// caches and reports them as 0 bytes. Applying that 0 to a catalog row
    /// drops it below the popover's `sizeBytes > 0` filter until the privileged
    /// size query restores it — the disappear/reappear flicker. So catalog rows
    /// must keep their existing (privileged) size through the unprivileged pass.
    func test_applyingScanEntries_skipsCatalogSystemRows() {
        let entry = SystemCacheCatalog.entries[0]   // iconservices — root-only catalog cache
        let systemPath = URL(fileURLWithPath: entry.path)
        let rows = [
            CachePathRow(displayName: entry.displayName,
                         path: systemPath,
                         sizeBytes: 8192, risk: .safe,
                         autoCleanEnabled: false, isSystem: true)
        ]
        // Unprivileged walk reports the unreadable catalog dir as 0 bytes.
        let scanned = [CacheReport.Entry(path: systemPath, exists: true, fileCount: 0, bytes: 0)]
        let out = MenuBarViewModel.applyingScanEntries(rows, entries: scanned)
        XCTAssertEqual(out[0].sizeBytes, 8192, "catalog row keeps its privileged size")
        XCTAssertTrue(out[0].exists)
    }

    /// User-added system-scope folders (outside `$HOME`, e.g. a third-party
    /// `/Library/Caches/...`) are `isSystem && isCustom` but have NO catalog
    /// identifier — the privileged helper never sizes them. Their only size
    /// source is the unprivileged walk, so the skip must be catalog-scoped, not
    /// blanket `isSystem`, or these rows stay stuck at 0 and vanish.
    func test_applyingScanEntries_sizesNonCatalogSystemRow() {
        let path = URL(fileURLWithPath: "/Library/Caches/com.example.thirdparty")
        XCTAssertNil(SystemCacheCatalog.identifier(for: path), "precondition: not a catalog path")
        let rows = [
            CachePathRow(displayName: "Third-party",
                         path: path,
                         sizeBytes: 0, risk: .caution,
                         autoCleanEnabled: false, isCustom: true, isSystem: true)
        ]
        let scanned = [CacheReport.Entry(path: path, exists: true, fileCount: 2, bytes: 7000)]
        let out = MenuBarViewModel.applyingScanEntries(rows, entries: scanned)
        XCTAssertEqual(out[0].sizeBytes, 7000, "non-catalog system tracking row sized from the walk")
        XCTAssertTrue(out[0].exists)
    }

    func test_applyingScanEntries_updatesNormalRows() {
        let path = URL(fileURLWithPath: "/tmp/normal-cache")
        let rows = [
            CachePathRow(displayName: "Normal",
                         path: path,
                         sizeBytes: 0, risk: .safe,
                         autoCleanEnabled: false, isSystem: false)
        ]
        let entries = [CacheReport.Entry(path: path, exists: true, fileCount: 3, bytes: 5000)]
        let out = MenuBarViewModel.applyingScanEntries(rows, entries: entries)
        XCTAssertEqual(out[0].sizeBytes, 5000, "normal row sized from the walk")
        XCTAssertTrue(out[0].exists)
    }
}
