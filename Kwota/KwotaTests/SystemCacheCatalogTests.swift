//
//  SystemCacheCatalogTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

final class SystemCacheCatalogTests: XCTestCase {

    func testCatalogContainsIconServicesEntry() {
        let entry = SystemCacheCatalog.entry(for: "iconservices")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.path, "/Library/Caches/com.apple.iconservices.store")
        XCTAssertTrue(entry?.restartsFinder == true)
    }

    func testUnknownIdentifierIsRejected() {
        XCTAssertNil(SystemCacheCatalog.entry(for: "../../etc/passwd"))
        XCTAssertNil(SystemCacheCatalog.entry(for: ""))
        XCTAssertNil(SystemCacheCatalog.entry(for: "iconservices "))
    }

    func testReverseLookupMatchesCatalogPath() {
        let url = URL(fileURLWithPath: "/Library/Caches/com.apple.iconservices.store")
        XCTAssertEqual(SystemCacheCatalog.identifier(for: url), "iconservices")
    }

    func testReverseLookupRejectsNonCatalogURL() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent("Library/Caches/Yarn")
        XCTAssertNil(SystemCacheCatalog.identifier(for: url))
    }

    func testEntryIdentifiersAreUnique() {
        let ids = SystemCacheCatalog.entries.map(\.identifier)
        XCTAssertEqual(ids.count, Set(ids).count, "catalog identifiers must be unique")
    }
}
