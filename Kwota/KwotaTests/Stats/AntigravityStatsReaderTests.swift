//  AntigravityStatsReaderTests.swift
//  KwotaTests

import XCTest
import SQLite3
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

    /// A malformed row is skipped; surrounding valid rows still emit (and the
    /// cursor advances past them — the failed row is deferred for retry).
    func test_read_softDegradesOnMalformedRow() throws {
        let good = F.genBlob(input: 100, output: 10, cache: 0, thinking: 0, ts: 1_781_344_340)
        let junk = Data([0x0a, 0xff, 0xff])   // truncated — not a usage row
        let (root, _) = try F.makeConversationDB(blobs: [good, junk, good])
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(AntigravityStatsReader(roots: [root]).read().count, 2)
    }

    /// A decode failure in a MIXED batch must not let the cursor silently skip
    /// the bad row forever: it advances past it (valid rows after it still emit)
    /// but the failed idx is remembered and recovered once it becomes decodable.
    func test_read_deferredRetry_recoversFailedRowAfterItBecomesDecodable() throws {
        let good0 = F.genBlob(input: 100, output: 10, cache: 0, thinking: 0, ts: 1_781_344_340)
        let junk  = Data([0x0a, 0xff, 0xff])
        let good2 = F.genBlob(input: 200, output: 20, cache: 0, thinking: 0, ts: 1_781_344_360)
        let (root, db) = try F.makeConversationDB(blobs: [good0, junk, good2])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = AntigravityStatsReader(roots: [root])
        XCTAssertEqual(reader.read().count, 2, "valid rows emit; the junk row doesn't block them")
        XCTAssertEqual(reader.state().entries.values.first?.failedIdx, [1], "failed idx remembered")
        XCTAssertEqual(reader.state().entries.values.first?.offset, 2, "cursor advanced past the junk row")

        // The row becomes decodable (decoder fix simulated by fixing the bytes).
        let fixed = F.genBlob(input: 50, output: 5, cache: 0, thinking: 0, ts: 1_781_344_350)
        try F.updateBlob(db: db, idx: 1, blob: fixed)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: db.path)

        let again = reader.read()
        XCTAssertEqual(again.count, 1, "the previously-failed row is recovered via deferred retry")
        XCTAssertEqual(again[0].tokens.input, 50)
        XCTAssertNil(reader.state().entries.values.first?.failedIdx, "recovered idx cleared")
    }

    /// Valid ZERO-TOKEN rows mixed with one malformed row must NOT be mistaken for
    /// whole-batch decode drift: the zero-token rows decoded cleanly, so the cursor
    /// advances (the malformed idx deferring for retry) instead of the DB being
    /// reopened/rescanned on every 5-minute poll. Regression for the drift guard
    /// ignoring `.zeroToken` decodes.
    func test_read_zeroTokenRowsWithOneFailure_advanceCursorNotDrift() throws {
        let zero0 = F.genBlob(input: 0, output: 0, cache: 0, thinking: 0, ts: 1_781_344_340)
        let zero1 = F.genBlob(input: 0, output: 0, cache: 0, thinking: 0, ts: 1_781_344_350)
        let junk  = Data([0x0a, 0xff, 0xff])
        let (root, _) = try F.makeConversationDB(blobs: [zero0, zero1, junk])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = AntigravityStatsReader(roots: [root])
        XCTAssertTrue(reader.read().isEmpty, "zero-token rows aren't billable, so nothing emits")
        let entry = reader.state().entries.values.first
        XCTAssertEqual(entry?.offset, 2, "cursor advances past zero-token + junk (not held as drift)")
        XCTAssertEqual(entry?.failedIdx, [2], "the lone malformed row defers for retry")
    }

    /// Non-usage gen_metadata rows (no `1.4.2`) decode cleanly as "not a usage
    /// row". They must advance the cursor and NOT land in `failed` — otherwise the
    /// unchanged-file fast path is disabled and the DB is reopened/re-queried on
    /// every 5-minute poll forever.
    func test_read_nonUsageRowsAdvanceCursor_andDoNotPoisonFailed() throws {
        let nonUsage0 = F.mfield(1, F.sfield(19, "gemini-pro-default"))
        let nonUsage1 = F.mfield(1, F.sfield(19, "gemini-pro-default"))
        let (root, _) = try F.makeConversationDB(blobs: [nonUsage0, nonUsage1])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = AntigravityStatsReader(roots: [root])
        XCTAssertTrue(reader.read().isEmpty, "non-usage rows emit nothing")
        let entry = reader.state().entries.values.first
        XCTAssertEqual(entry?.offset, 1, "cursor advanced past the non-usage rows")
        XCTAssertNil(entry?.failedIdx, "non-usage rows are not retryable failures")
    }

    /// A non-usage row mixed with a billable one: the billable row emits and the
    /// non-usage row neither blocks it nor poisons `failed`.
    func test_read_nonUsageRowMixedWithBillable_emitsBillableKeepsFailedEmpty() throws {
        let nonUsage = F.mfield(1, F.sfield(19, "gemini-pro-default"))
        let billable = F.genBlob(input: 100, output: 10, cache: 0, thinking: 0, ts: 1_781_344_340)
        let (root, _) = try F.makeConversationDB(blobs: [nonUsage, billable])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = AntigravityStatsReader(roots: [root])
        XCTAssertEqual(reader.read().map(\.tokens.input), [100], "billable row emits; non-usage ignored")
        let entry = reader.state().entries.values.first
        XCTAssertNil(entry?.failedIdx, "non-usage row is not a failure")
        XCTAssertEqual(entry?.offset, 1, "cursor advanced past both rows")
    }

    /// The deferred-retry set survives state()/restore(): a still-failing idx is
    /// re-attempted after a relaunch (and the cursor isn't rewound to re-emit
    /// the rows that already succeeded).
    func test_read_failedIdxSurvivesStateRestore() throws {
        let good = F.genBlob(input: 100, output: 10, cache: 0, thinking: 0, ts: 1_781_344_340)
        let junk = Data([0x0a, 0xff, 0xff])
        let (root, _) = try F.makeConversationDB(blobs: [good, junk])
        defer { try? FileManager.default.removeItem(at: root) }

        let r1 = AntigravityStatsReader(roots: [root])
        XCTAssertEqual(r1.read().count, 1)
        let saved = r1.state()
        XCTAssertEqual(saved.entries.values.first?.failedIdx, [1])

        let r2 = AntigravityStatsReader(roots: [root])
        r2.restore(saved)
        XCTAssertTrue(r2.read().isEmpty, "good row not re-emitted; junk retried but still fails")
        XCTAssertEqual(r2.state().entries.values.first?.failedIdx, [1], "still-failing idx stays remembered")
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

    /// A DB reset that shrinks the table below the high-water is detected and
    /// re-read from scratch (the reader's one novel double-count guard).
    func test_read_resetsAndReReadsOnShrink() throws {
        let b0 = F.genBlob(input: 100, output: 10, cache: 0, thinking: 0, ts: 1_781_344_340)
        let b1 = F.genBlob(input: 200, output: 20, cache: 0, thinking: 0, ts: 1_781_344_350)
        let b2 = F.genBlob(input: 300, output: 30, cache: 0, thinking: 0, ts: 1_781_344_360)
        let (root, db) = try F.makeConversationDB(blobs: [b0, b1, b2])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = AntigravityStatsReader(roots: [root])
        XCTAssertEqual(reader.read().count, 3)   // backfill, high-water = idx 2

        // Simulate a conversation reset: recreate the DB with a single low-idx row.
        try FileManager.default.removeItem(at: db)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: db.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: db.path + "-shm"))
        let fresh = F.genBlob(input: 999, output: 1, cache: 0, thinking: 0, ts: 1_781_344_999)
        try F.writeGenMetadata(db: db, blobs: [fresh], startIdx: 0)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: db.path)

        let after = reader.read()
        XCTAssertEqual(after.count, 1)            // re-read from scratch, not skipped
        XCTAssertEqual(after[0].tokens.input, 999)
    }

    /// WAL-mode append: a new row lands in the `-wal` sidecar without changing
    /// the main DB file's mtime/size. The gate must not skip it (it must read
    /// the new WAL-committed row), or live token usage goes missing until a
    /// checkpoint. Faithful repro: a held-open WAL writer that never checkpoints.
    func test_read_walAppendNotSkipped_whenMainDbUnchanged() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-wal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("\(UUID().uuidString).db")

        let writer = try F.openWALWriter(db: db)
        defer { sqlite3_close(writer) }

        try F.insertWAL(writer, blobs: [F.genBlob(input: 100, output: 10, cache: 0, thinking: 0, ts: 1_781_344_340)], startIdx: 0)
        let reader = AntigravityStatsReader(roots: [root])
        XCTAssertEqual(reader.read().count, 1, "first read should see the WAL-committed row 0")

        let mainBefore = try FileManager.default.attributesOfItem(atPath: db.path)
        try F.insertWAL(writer, blobs: [F.genBlob(input: 200, output: 20, cache: 0, thinking: 0, ts: 1_781_344_350)], startIdx: 1)
        let mainAfter = try FileManager.default.attributesOfItem(atPath: db.path)
        // Sanity: the WAL append really did leave the main DB file unchanged.
        XCTAssertEqual(mainBefore[.size] as? UInt64, mainAfter[.size] as? UInt64)
        XCTAssertEqual(mainBefore[.modificationDate] as? Date, mainAfter[.modificationDate] as? Date)

        let events = reader.read()
        XCTAssertEqual(events.count, 1, "WAL append must not be skipped by the change gate")
        XCTAssertEqual(events[0].tokens.input, 200)
    }

    /// Whole-batch decode failure (proto drift) must NOT advance the high-water,
    /// or the un-decodable rows are skipped forever once the decoder is fixed.
    func test_read_doesNotAdvanceCursor_whenWholeBatchFailsToDecode() throws {
        let junk = Data([0x0a, 0xff, 0xff])   // truncated — fails to decode
        let (root, db) = try F.makeConversationDB(blobs: [junk, junk])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = AntigravityStatsReader(roots: [root])
        XCTAssertEqual(reader.read().count, 0)
        XCTAssertEqual(reader.state().entries.count, 0,
                       "cursor must not advance when every row fails to decode")

        // A later valid append still emits, and because the cursor never moved the
        // earlier rows remain re-readable (here: re-scanned and skipped per-row).
        let good = F.genBlob(input: 100, output: 10, cache: 0, thinking: 0, ts: 1_781_344_340)
        try F.writeGenMetadata(db: db, blobs: [good], startIdx: 2)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: db.path)

        let events = reader.read()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].tokens.input, 100)
    }

    /// Rows that decode cleanly but carry zero billable tokens are accounted for
    /// (just empty), so the cursor MUST advance — they are not proto drift.
    func test_read_advancesCursor_whenRowsAreValidButZeroToken() throws {
        let zero = F.genBlob(input: 0, output: 0, cache: 0, thinking: 0, ts: 1_781_344_340)
        let (root, _) = try F.makeConversationDB(blobs: [zero, zero])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = AntigravityStatsReader(roots: [root])
        XCTAssertEqual(reader.read().count, 0)            // zero-token rows emit nothing…
        XCTAssertEqual(reader.state().entries.count, 1)   // …but advance the cursor
    }

    /// A DB with an empty gen_metadata table emits nothing and records no cursor.
    func test_read_handlesEmptyTable() throws {
        let (root, _) = try F.makeConversationDB(blobs: [])
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = AntigravityStatsReader(roots: [root])
        XCTAssertEqual(reader.read().count, 0)
        XCTAssertEqual(reader.state().entries.count, 0)
    }
}
