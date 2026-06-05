//
//  CacheCleanerTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class CacheCleanerTests: XCTestCase {
    func testReportsFilesUnderEachConfiguredPath() throws {
        let tmp = TempDirectory()
        let a = tmp.file("a"); let b = tmp.file("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: a.appendingPathComponent("one.txt"))
        try Data("hello".utf8).write(to: b.appendingPathComponent("two.log"))

        let report = CacheCleaner(targets: [a, b]).scan()

        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(report.totalFiles, 2)
        XCTAssertEqual(report.totalBytes, 7)
    }

    func testMissingPathsAreReportedWithZeroFiles() {
        let tmp = TempDirectory()
        let report = CacheCleaner(targets: [tmp.file("does-not-exist")]).scan()

        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries[0].fileCount, 0)
        XCTAssertFalse(report.entries[0].exists)
    }

    func testScanDoesNotMutateFilesystem() throws {
        let tmp = TempDirectory()
        let dir = tmp.file("cache")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: f)

        _ = CacheCleaner(targets: [dir]).scan()

        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testScanDoesNotFalselyTruncateNormalDirectory() throws {
        let tmp = TempDirectory()
        let dir = tmp.file("cache")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("world".utf8).write(to: dir.appendingPathComponent("b.txt"))

        let report = CacheCleaner(targets: [dir]).scan()
        let entry = report.entries.first { $0.path == dir }
        XCTAssertNotNil(entry)
        XCTAssertFalse(entry!.truncated,
                       "a tiny directory must complete well within the time budget")
        XCTAssertEqual(entry!.fileCount, 2)
    }

    // MARK: - scanConcurrent()

    func testScanConcurrentReportsAllPaths() async throws {
        let tmp = TempDirectory()
        // 6 dirs > the default maxConcurrent of 4 so the worker-pool refill
        // path actually runs.
        var dirs: [URL] = []
        var expectedBytes = 0
        for i in 0..<6 {
            let d = tmp.file("p\(i)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let payload = Data(repeating: 0x41, count: (i + 1) * 100)  // 100, 200, 300, ...
            try payload.write(to: d.appendingPathComponent("f.bin"))
            dirs.append(d)
            expectedBytes += payload.count
        }
        let cleaner = CacheCleaner(targets: dirs)
        let report = await cleaner.scanConcurrent()
        XCTAssertEqual(report.entries.count, 6)
        XCTAssertEqual(report.totalFiles, 6)
        XCTAssertEqual(report.totalBytes, expectedBytes)
        // Every input dir is represented (order is completion order, not
        // submission order — match by path).
        let pathsSeen = Set(report.entries.map(\.path))
        XCTAssertEqual(pathsSeen, Set(dirs))
    }

    func testScanConcurrentHandlesMissingPaths() async throws {
        let tmp = TempDirectory()
        let real = tmp.file("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: real.appendingPathComponent("a.txt"))
        let missing = tmp.file("missing-folder")

        let cleaner = CacheCleaner(targets: [real, missing])
        let report = await cleaner.scanConcurrent()
        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(report.totalBytes, 2)
        XCTAssertTrue(report.entries.contains { $0.path == missing && !$0.exists })
        XCTAssertTrue(report.entries.contains { $0.path == real && $0.exists })
    }

    // MARK: - scanStream()

    func testScanStreamYieldsEveryPathExactlyOnce() async throws {
        let tmp = TempDirectory()
        var dirs: [URL] = []
        for i in 0..<5 {
            let d = tmp.file("p\(i)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: (i + 1) * 10).write(to: d.appendingPathComponent("f.bin"))
            dirs.append(d)
        }
        let cleaner = CacheCleaner(targets: dirs)
        var seen: [URL] = []
        var totalBytes = 0
        for await entry in cleaner.scanStream() {
            seen.append(entry.path)
            totalBytes += entry.bytes
        }
        // Each path emitted exactly once; totals match the canonical scan.
        XCTAssertEqual(Set(seen), Set(dirs))
        XCTAssertEqual(seen.count, dirs.count)
        XCTAssertEqual(totalBytes, (10 + 20 + 30 + 40 + 50))
    }

    func testScanStreamFinishesEvenWhenAllPathsMissing() async {
        let tmp = TempDirectory()
        let missing = [tmp.file("a"), tmp.file("b")]
        let cleaner = CacheCleaner(targets: missing)
        var count = 0
        for await entry in cleaner.scanStream() {
            XCTAssertFalse(entry.exists)
            count += 1
        }
        XCTAssertEqual(count, 2, "missing paths still emit an entry so caller can mark exists=false")
    }

    // MARK: - clean()

    func testCleanMissingPathReportsZero() {
        let tmp = TempDirectory()
        let report = CacheCleaner(targets: [tmp.file("does-not-exist")]).clean()

        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries[0].bytesFreed, 0)
        XCTAssertEqual(report.entries[0].itemsMoved, 0)
        XCTAssertNil(report.entries[0].firstError)
        XCTAssertEqual(report.entries[0].trashedItemURLs, [])
    }

    func testCleanEmptyFolderReportsZero() throws {
        let tmp = TempDirectory()
        let target = tmp.file("empty-cache")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let report = CacheCleaner(targets: [target]).clean()

        XCTAssertEqual(report.entries[0].itemsMoved, 0)
        XCTAssertEqual(report.entries[0].bytesFreed, 0)
        // Root dir must remain — some tools expect their cache root to
        // exist on the next invocation.
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    /// Note: this exercises `FileManager.trashItem` against the real user
    /// Trash. Each run leaves a uniquely-named folder + file in Trash; safe
    /// to empty alongside other Trash items. The alternative (mocking
    /// trashItem) would require an FS abstraction we don't have yet — not
    /// worth introducing for a single test.
    func testCleanMovesChildrenToTrashAndPreservesRoot() throws {
        let tmp = TempDirectory()
        // Unique suffix so artifacts in the user's Trash are recognisable
        // and don't collide between runs.
        let suffix = UUID().uuidString.prefix(8)
        let target = tmp.file("kwota-test-cache-\(suffix)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let file = target.appendingPathComponent("kwota-test-file-\(suffix).txt")
        try Data("hello".utf8).write(to: file)

        let subdir = target.appendingPathComponent("kwota-test-subdir-\(suffix)")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try Data("world".utf8).write(to: subdir.appendingPathComponent("inner.txt"))

        let report = CacheCleaner(targets: [target]).clean()

        // Root preserved.
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        // Children gone from source location.
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: subdir.path))
        // Report has correct counts: 2 top-level children moved.
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries[0].itemsMoved, 2)
        // Bytes: "hello" (5) + sizeOf(subdir) = "world" inside (5) = 10.
        XCTAssertEqual(report.totalBytesFreed, 10)
        XCTAssertNil(report.entries[0].firstError)
    }

    /// Permanent-delete mode: children are removed outright, not trashed.
    /// Everything lives under a `TempDirectory`, so a hard delete here is
    /// safe and doesn't touch the user's real files or Trash.
    func testCleanPermanentlyDeletesChildrenAndTracksNothing() throws {
        let tmp = TempDirectory()
        let target = tmp.file("perm-cache")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let file = target.appendingPathComponent("file.txt")
        try Data("hello".utf8).write(to: file)
        let subdir = target.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try Data("world".utf8).write(to: subdir.appendingPathComponent("inner.txt"))

        let report = CacheCleaner(targets: [target], deletePermanently: true).clean()

        // Root preserved, children gone.
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: subdir.path))
        // Counts match the trash path…
        XCTAssertEqual(report.entries[0].itemsMoved, 2)
        XCTAssertEqual(report.totalBytesFreed, 10)
        XCTAssertNil(report.entries[0].firstError)
        // …but nothing reached the Trash, so there's nothing for the
        // auto-empty sweep to track.
        XCTAssertEqual(report.entries[0].trashedItemURLs, [])
    }
}
