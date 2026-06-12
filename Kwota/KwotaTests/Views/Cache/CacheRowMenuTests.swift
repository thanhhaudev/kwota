//
//  CacheRowMenuTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

/// `CacheRowMenu.CleanBlock.current` mirrors the re-entrancy guard in
/// `MenuBarViewModel.cacheCleanRow` — these tests pin the mapping so the
/// menu's disabled-with-reason state can't drift from what the VM actually
/// rejects.
@MainActor
final class CacheRowMenuTests: XCTestCase {

    func test_cleanBlock_idle_isNil() {
        XCTAssertNil(CacheRowMenu.CleanBlock.current(
            isScanning: false, isCleaningGlobal: false, hasRowCleans: false
        ))
    }

    func test_cleanBlock_scanning_returnsScanning() {
        XCTAssertEqual(CacheRowMenu.CleanBlock.current(
            isScanning: true, isCleaningGlobal: false, hasRowCleans: false
        ), .scanning)
    }

    func test_cleanBlock_globalClean_returnsCleaning() {
        XCTAssertEqual(CacheRowMenu.CleanBlock.current(
            isScanning: false, isCleaningGlobal: true, hasRowCleans: false
        ), .cleaning)
    }

    func test_cleanBlock_rowCleanInFlight_returnsCleaning() {
        XCTAssertEqual(CacheRowMenu.CleanBlock.current(
            isScanning: false, isCleaningGlobal: false, hasRowCleans: true
        ), .cleaning)
    }

    /// Global Clean now flips `isScanning` alongside `isCleaning` (the
    /// confirmed clean runs a forced rescan) — the scan label wins because
    /// that's the activity the footer shows the user.
    func test_cleanBlock_scanWinsOverClean() {
        XCTAssertEqual(CacheRowMenu.CleanBlock.current(
            isScanning: true, isCleaningGlobal: true, hasRowCleans: true
        ), .scanning)
    }

    func test_menuSuffix_copy() {
        XCTAssertEqual(CacheRowMenu.CleanBlock.scanning.menuSuffix, "waiting for scan…")
        XCTAssertEqual(CacheRowMenu.CleanBlock.cleaning.menuSuffix, "waiting for cleanup…")
    }
}
