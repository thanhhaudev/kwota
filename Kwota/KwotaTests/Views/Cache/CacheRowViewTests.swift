//
//  CacheRowViewTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class CacheRowViewTests: XCTestCase {

    // MARK: - CachePathDisplay.abbreviate

    func test_abbreviate_insideHome_dropsPrefix() {
        let r = CachePathDisplay.abbreviate("/Users/hau/Library/Caches/Claude", home: "/Users/hau")
        XCTAssertTrue(r.inHome)
        XCTAssertEqual(r.display, "Library/Caches/Claude")
    }

    func test_abbreviate_homeWithTrailingSlash() {
        let r = CachePathDisplay.abbreviate("/Users/hau/.npm", home: "/Users/hau/")
        XCTAssertTrue(r.inHome)
        XCTAssertEqual(r.display, ".npm")
    }

    func test_abbreviate_outsideHome_passesThrough() {
        let r = CachePathDisplay.abbreviate("/Library/Caches/Foo", home: "/Users/hau")
        XCTAssertFalse(r.inHome)
        XCTAssertEqual(r.display, "/Library/Caches/Foo")
    }

    func test_abbreviate_homeItself_passesThrough() {
        let r = CachePathDisplay.abbreviate("/Users/hau", home: "/Users/hau")
        XCTAssertFalse(r.inHome)
        XCTAssertEqual(r.display, "/Users/hau")
    }

    func test_abbreviate_siblingUserNotConfusedWithHome() {
        // "/Users/hau2" must not match home "/Users/hau" — the prefix check
        // is segment-aware via the appended slash.
        let r = CachePathDisplay.abbreviate("/Users/hau2/Library/Caches", home: "/Users/hau")
        XCTAssertFalse(r.inHome)
        XCTAssertEqual(r.display, "/Users/hau2/Library/Caches")
    }

    func test_abbreviate_emptyHome_passesThrough() {
        let r = CachePathDisplay.abbreviate("/anything", home: "")
        XCTAssertFalse(r.inHome)
        XCTAssertEqual(r.display, "/anything")
    }
}
