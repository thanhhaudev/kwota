//  CodexTraceReaderTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

/// Test double that conforms to `CodexFileManager`: makes the sessions
/// enumerator fail on demand and counts how many times it's called so we can
/// prove fail-closed + walk-gating. Delegates everything else to the real
/// `FileManager.default` so existing fixture IO is unaffected.
private final class SpyFileManager: CodexFileManager, @unchecked Sendable {
    var failEnumerator = false
    var simulateTraversalError = false
    var enumeratorCalls = 0
    private let real = FileManager.default

    func contentsOfDirectory(at url: URL,
                             includingPropertiesForKeys keys: [URLResourceKey]?,
                             options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        try real.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }

    func enumerator(at url: URL,
                    includingPropertiesForKeys keys: [URLResourceKey]?,
                    options mask: FileManager.DirectoryEnumerationOptions,
                    errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
        enumeratorCalls += 1
        if failEnumerator { return nil }
        if simulateTraversalError {
            _ = handler?(url, NSError(domain: "test", code: 1))   // simulate a descendant error
        }
        return real.enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: handler)
    }

    func fileExists(atPath path: String) -> Bool { real.fileExists(atPath: path) }

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try real.attributesOfItem(atPath: path)
    }
}

final class CodexTraceReaderTests: XCTestCase {
    private var home: URL!
    override func tearDown() { if let home { CodexTraceFixture.cleanup(home) }; home = nil }

    // ts: 2026-06-15T00:00:00Z = 1781481600
    private let ts: Int64 = 1_781_481_600

    func test_parsesUsageRow_intoTokenBreakdownAndModel() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tA",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 100, cached: 70, output: 8)),
        ])
        let events = CodexTraceReader(codexHome: home).read()
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e.model, "gpt-5.5")
        XCTAssertEqual(e.sessionId, "tA")
        // input = input_tokens - cached; cacheRead = cached; output as-is.
        XCTAssertEqual(e.tokens, TokenBreakdown(input: 30, output: 8, cacheCreation: 0, cacheRead: 70))
        XCTAssertEqual(e.timestamp, Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    func test_skipsZeroTokenRows() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tA",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 0, cached: 0, output: 0)),
        ])
        XCTAssertTrue(CodexTraceReader(codexHome: home).read().isEmpty)
    }

    func test_ignoresNonUsageTargetRows() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tA",
                  body: "some trace line with no usage", target: "codex_core::session::turn"),
        ])
        XCTAssertTrue(CodexTraceReader(codexHome: home).read().isEmpty)
    }

    func test_cursorIsIncremental_secondReadSeesOnlyNewRows() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tA",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 10, cached: 0, output: 1)),
        ])
        let reader = CodexTraceReader(codexHome: home)
        XCTAssertEqual(reader.read().count, 1)
        XCTAssertTrue(reader.read().isEmpty, "no new rows -> nothing re-emitted")
        // append a new row at a higher id
        CodexTraceFixture.writeDB(at: home.appendingPathComponent("logs_2.sqlite"), rows: [
            .init(id: 1, ts: ts, threadId: "tA",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 10, cached: 0, output: 1)),
            .init(id: 2, ts: ts, threadId: "tB",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 20, cached: 0, output: 2)),
        ])
        let next = reader.read()
        XCTAssertEqual(next.map(\.sessionId), ["tB"])
    }

    func test_excludesThreadsThatHaveARollout() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tEphemeral",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 10, cached: 0, output: 1)),
            .init(id: 2, ts: ts, threadId: "tPersisted",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 99, cached: 0, output: 9)),
        ])
        CodexTraceFixture.addRollout(home: home, threadId: "tPersisted")
        let events = CodexTraceReader(codexHome: home).read()
        XCTAssertEqual(events.map(\.sessionId), ["tEphemeral"], "rollout-backed thread already counted elsewhere")
    }

    func test_readOnly_acceptsOnlyLogsSqlitePaths() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tA",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 10, cached: 0, output: 1)),
        ])
        let reader = CodexTraceReader(codexHome: home)
        // a rollout path must be ignored by the trace reader
        let rolloutURL = home.appendingPathComponent("sessions/x/rollout-2026-06-15T10-00-00-tA.jsonl")
        XCTAssertTrue(reader.read(only: [rolloutURL]).isEmpty)
        let dbURL = home.appendingPathComponent("logs_2.sqlite")
        XCTAssertEqual(reader.read(only: [dbURL]).count, 1)
    }

    func test_stateRestore_roundTripsCursor() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tA",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 10, cached: 0, output: 1)),
        ])
        let r1 = CodexTraceReader(codexHome: home)
        _ = r1.read()
        let saved = r1.state()
        let r2 = CodexTraceReader(codexHome: home)
        r2.restore(saved)
        XCTAssertTrue(r2.read().isEmpty, "restored cursor must not re-emit consumed rows")
    }

    func test_rotation_whenMaxIdDropsBelowCursor_reReadsFromScratch() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 5, ts: ts, threadId: "tA",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 10, cached: 0, output: 1)),
        ])
        let reader = CodexTraceReader(codexHome: home)
        XCTAssertEqual(reader.read().count, 1)   // cursor -> 5
        // replace the DB with a smaller max id (reset/rotation)
        CodexTraceFixture.writeDB(at: home.appendingPathComponent("logs_2.sqlite"), rows: [
            .init(id: 1, ts: ts, threadId: "tNew",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 7, cached: 0, output: 1)),
        ])
        XCTAssertEqual(reader.read().map(\.sessionId), ["tNew"])
    }

    func test_failClosed_whenSessionsExistsButUnreadable_skipsIngest() {
        // sessions/ EXISTS (a rollout present) but enumerator fails → the
        // exclusion set is untrusted, so we must NOT ingest (and not advance).
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: 1_781_481_600, threadId: "tA",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 10, cached: 0, output: 1)),
        ])
        CodexTraceFixture.addRollout(home: home, threadId: "whatever")   // makes sessions/ exist
        let spy = SpyFileManager(); spy.failEnumerator = true
        let reader = CodexTraceReader(codexHome: home, fileManager: spy)
        XCTAssertTrue(reader.read().isEmpty, "untrusted exclusion set → skip ingest")
        XCTAssertTrue(reader.state().entries.isEmpty, "cursor must NOT advance when skipped")
    }

    func test_idleRead_doesNotWalkSessions() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: 1_781_481_600, threadId: "tA",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 10, cached: 0, output: 1)),
        ])
        let spy = SpyFileManager()
        let reader = CodexTraceReader(codexHome: home, fileManager: spy)
        XCTAssertEqual(reader.read().count, 1)              // first read ingests + walks sessions
        let afterFirst = spy.enumeratorCalls
        XCTAssertTrue(reader.read().isEmpty)                // no new rows
        XCTAssertEqual(spy.enumeratorCalls, afterFirst, "idle read must NOT walk the sessions tree again")
    }

    func test_failClosed_onPartialTraversalError_skipsIngest() {
        // A rollout exists for an UNRELATED thread; the usage row is a different
        // (ephemeral) thread that would normally be ingested. A traversal error
        // makes the exclusion set partial/untrusted → skip the whole read.
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: 1_781_481_600, threadId: "tEphemeral",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 10, cached: 0, output: 1)),
        ])
        CodexTraceFixture.addRollout(home: home, threadId: "tOther")
        let spy = SpyFileManager(); spy.simulateTraversalError = true
        let reader = CodexTraceReader(codexHome: home, fileManager: spy)
        XCTAssertTrue(reader.read().isEmpty, "traversal error → untrusted exclusion → skip ingest")
        XCTAssertTrue(reader.state().entries.isEmpty, "cursor must NOT advance when skipped")
    }

    func test_unrelatedTraceRows_advanceCursorWithoutWalkingSessions() {
        // A DB with ONLY non-usage rows must NOT trigger a sessions walk, but the
        // cursor should still advance so the rows aren't re-scanned forever.
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: 1_781_481_600, threadId: "tA",
                  body: "unrelated trace line", target: "codex_core::session::turn"),
            .init(id: 2, ts: 1_781_481_600, threadId: "tA",
                  body: "another unrelated line", target: "codex_core::session::turn"),
        ])
        let spy = SpyFileManager()
        let reader = CodexTraceReader(codexHome: home, fileManager: spy)
        XCTAssertTrue(reader.read().isEmpty, "no usage rows → nothing emitted")
        XCTAssertEqual(spy.enumeratorCalls, 0, "no usage rows → no sessions walk")
        XCTAssertFalse(reader.state().entries.isEmpty, "cursor advanced past unrelated rows")
        // A later USAGE row IS picked up (cursor advanced, not stuck).
        CodexTraceFixture.addRollout(home: home, threadId: "tUnrelated")   // make sessions/ exist so the walk enumerates
        CodexTraceFixture.writeDB(at: home.appendingPathComponent("logs_2.sqlite"), rows: [
            .init(id: 1, ts: 1_781_481_600, threadId: "tA",
                  body: "unrelated trace line", target: "codex_core::session::turn"),
            .init(id: 2, ts: 1_781_481_600, threadId: "tA",
                  body: "another unrelated line", target: "codex_core::session::turn"),
            .init(id: 3, ts: 1_781_481_600, threadId: "tB",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 7, cached: 0, output: 1)),
        ])
        XCTAssertEqual(reader.read().map(\.sessionId), ["tB"])
        XCTAssertGreaterThan(spy.enumeratorCalls, 0, "usage row present → sessions walk happens")
    }
}
