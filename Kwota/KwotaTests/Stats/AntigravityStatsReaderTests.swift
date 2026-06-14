//  AntigravityStatsReaderTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

final class AntigravityStatsReaderTests: XCTestCase {
    typealias F = AntigravityProtoFixture

    func test_appPaths_conversationDirs_coverIDEAndCLI() {
        let paths = AppPaths.antigravityConversationDirs.map(\.path)
        XCTAssertTrue(paths.contains { $0.hasSuffix("/.gemini/antigravity/conversations") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("/.gemini/antigravity-cli/conversations") })
    }

    /// First sight of a DB backfills every row with its real timestamp.
    func test_read_backfillsAllRowsWithRealTimestamps() throws {
        let b0 = F.genBlob(input: 100, output: 10, cache: 0, thinking: 0, ts: 1_781_344_340)
        let b1 = F.genBlob(input: 200, output: 20, cache: 32000, thinking: 5, ts: 1_781_344_350)
        let (root, _) = try F.makeConversationDB(blobs: [b0, b1])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = AntigravityStatsReader(roots: [root])
        let events = reader.read()

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].timestamp, Date(timeIntervalSince1970: 1_781_344_340))
        XCTAssertEqual(events[0].tokens.input, 100)
        XCTAssertEqual(events[1].tokens.output, 20 + 5)
        XCTAssertEqual(events[1].tokens.cacheRead, 32000)
        XCTAssertEqual(events[1].model, "Gemini 3.1 Pro (High)")
    }

    /// A second read after the first emits nothing; a newly appended row emits only that row.
    func test_read_isIncrementalAcrossAppends() throws {
        let b0 = F.genBlob(input: 100, output: 10, cache: 0, thinking: 0, ts: 1_781_344_340)
        let (root, db) = try F.makeConversationDB(blobs: [b0])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = AntigravityStatsReader(roots: [root])
        XCTAssertEqual(reader.read().count, 1)
        XCTAssertEqual(reader.read().count, 0)   // nothing new

        let b1 = F.genBlob(input: 200, output: 20, cache: 0, thinking: 0, ts: 1_781_344_350)
        try F.writeGenMetadata(db: db, blobs: [b1], startIdx: 1)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: db.path)

        let again = reader.read()
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again[0].tokens.input, 200)
    }

    /// state()/restore() carry the high-water so a fresh reader doesn't re-emit.
    func test_stateRestore_preventsReEmit() throws {
        let b0 = F.genBlob(input: 100, output: 10, cache: 0, thinking: 0, ts: 1_781_344_340)
        let (root, _) = try F.makeConversationDB(blobs: [b0])
        defer { try? FileManager.default.removeItem(at: root) }

        let first = AntigravityStatsReader(roots: [root])
        XCTAssertEqual(first.read().count, 1)
        let saved = first.state()

        let second = AntigravityStatsReader(roots: [root])
        second.restore(saved)
        XCTAssertEqual(second.read().count, 0)
    }

    /// A row whose timestamp is absent inherits the previous row's timestamp.
    func test_read_fallsBackToPreviousTimestamp_whenRowHasNone() throws {
        let b0 = F.genBlob(input: 100, output: 10, cache: 0, thinking: 0, ts: 1_781_344_340)
        let b1 = F.genBlob(input: 200, output: 20, cache: 0, thinking: 0, ts: nil)
        let (root, _) = try F.makeConversationDB(blobs: [b0, b1])
        defer { try? FileManager.default.removeItem(at: root) }

        let events = AntigravityStatsReader(roots: [root]).read()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].timestamp, Date(timeIntervalSince1970: 1_781_344_340))
    }

    /// A malformed row is skipped; surrounding valid rows still emit.
    func test_read_softDegradesOnMalformedRow() throws {
        let good = F.genBlob(input: 100, output: 10, cache: 0, thinking: 0, ts: 1_781_344_340)
        let junk = Data([0x0a, 0xff, 0xff])   // truncated — not a usage row
        let (root, _) = try F.makeConversationDB(blobs: [good, junk, good])
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(AntigravityStatsReader(roots: [root]).read().count, 2)
    }

    /// A vanished DB's cursor is pruned from state() on the next full read.
    func test_read_prunesCursorForVanishedDB() throws {
        let b0 = F.genBlob(input: 100, output: 10, cache: 0, thinking: 0, ts: 1_781_344_340)
        let (root, db) = try F.makeConversationDB(blobs: [b0])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = AntigravityStatsReader(roots: [root])
        _ = reader.read()
        XCTAssertEqual(reader.state().entries.count, 1)

        try FileManager.default.removeItem(at: db)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: db.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: db.path + "-shm"))
        _ = reader.read()
        XCTAssertEqual(reader.state().entries.count, 0)
    }
}
