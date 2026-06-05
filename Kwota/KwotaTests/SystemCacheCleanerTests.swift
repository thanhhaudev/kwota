//
//  SystemCacheCleanerTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class SystemCacheCleanerTests: XCTestCase {

    func testClearContentsRemovesChildrenAndPreservesRoot() throws {
        let tmp = TempDirectory()
        let root = tmp.file("cache-root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("world".utf8).write(to: sub.appendingPathComponent("inner.txt"))

        let outcome = SystemCacheCleaner().clearContents(of: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path),
                      "the cache directory itself must be preserved")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        XCTAssertEqual(outcome.itemsRemoved, 2)
        XCTAssertEqual(outcome.bytesFreed, 10)   // "hello" + "world"
        XCTAssertNil(outcome.firstError)
    }

    func testMissingDirectoryIsANoOpSuccess() {
        let tmp = TempDirectory()
        let outcome = SystemCacheCleaner().clearContents(of: tmp.file("does-not-exist"))
        XCTAssertEqual(outcome.itemsRemoved, 0)
        XCTAssertEqual(outcome.bytesFreed, 0)
        XCTAssertNil(outcome.firstError)
    }

    func testEmptyDirectoryReportsZero() throws {
        let tmp = TempDirectory()
        let root = tmp.file("empty")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outcome = SystemCacheCleaner().clearContents(of: root)
        XCTAssertEqual(outcome.itemsRemoved, 0)
        XCTAssertEqual(outcome.bytesFreed, 0)
        XCTAssertNil(outcome.firstError)
    }

    func test_totalSize_sumsRegularFileBytes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0, count: 100).write(to: dir.appendingPathComponent("a"))
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 50).write(to: sub.appendingPathComponent("b"))

        XCTAssertEqual(SystemCacheCleaner().totalSize(of: dir), 150)
        XCTAssertEqual(SystemCacheCleaner().totalSize(of:
            dir.appendingPathComponent("missing")), 0)
    }
}
