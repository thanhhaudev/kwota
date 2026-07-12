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
    var failContentsOfDirectory = false
    private let real = FileManager.default

    func contentsOfDirectory(at url: URL,
                             includingPropertiesForKeys keys: [URLResourceKey]?,
                             options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        if failContentsOfDirectory { throw NSError(domain: "test", code: 2) }
        return try real.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
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

    // A batch whose only filter-matched rows fail `parseUsage` (the responses-API
    // usage shape drifted) must NOT advance the cursor past them, or the tokens are
    // lost permanently. Once the body becomes parseable, the row still emits.
    func test_wholeBatchParseFailure_holdsCursorUntilParseable() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tA",
                  body: "trace span input_tokens=42 but no usage object here"),
        ])
        let reader = CodexTraceReader(codexHome: home)
        XCTAssertTrue(reader.read().isEmpty, "unparseable usage row emits nothing")

        // Schema 'fixed': rewrite the same id with a parseable usage body.
        CodexTraceFixture.writeDB(at: home.appendingPathComponent("logs_2.sqlite"), rows: [
            .init(id: 1, ts: ts, threadId: "tA",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 10, cached: 0, output: 1)),
        ])
        XCTAssertEqual(reader.read().map(\.sessionId), ["tA"],
                       "cursor wasn't advanced past the failed row, so it emits after the fix")
    }

    // A lone unparseable row alongside a valid usage row advances normally: the
    // valid row emits and the cursor moves past BOTH, so the unparseable row is not
    // a re-scan poison pill (the LIKE filter can substring-match non-usage rows).
    func test_mixedParseFailure_advancesPastBothRows() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tA",
                  body: "trace span input_tokens mentioned but no usage object"),
            .init(id: 2, ts: ts, threadId: "tB",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 10, cached: 0, output: 1)),
        ])
        let reader = CodexTraceReader(codexHome: home)
        XCTAssertEqual(reader.read().map(\.sessionId), ["tB"], "valid row emits; unparseable one is skipped")
        XCTAssertTrue(reader.read().isEmpty, "cursor advanced past both rows -> nothing re-scanned")
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

    func test_fixtureCanStoreProcessUUIDAndNullThreadID() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: nil, processUUID: "pid:1",
                  body: CodexTraceFixture.responseCompletedBody(model: "gpt-5.5", input: 10, cached: 2, output: 3),
                  target: "log"),
        ])
        let rows = CodexTraceFixture.dumpRows(home: home)
        XCTAssertEqual(rows.first?.threadId, nil)
        XCTAssertEqual(rows.first?.processUUID, "pid:1")
    }

    func test_parsesResponseCompletedFromLogTarget() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tPlugin", processUUID: "pid:1",
                  body: CodexTraceFixture.responseCompletedBody(model: "gpt-5.5", input: 90, cached: 70, output: 6),
                  target: "log"),
        ])

        let events = CodexTraceReader(codexHome: home).read()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].sessionId, "tPlugin")
        XCTAssertEqual(events[0].model, "gpt-5.5")
        XCTAssertEqual(events[0].tokens, TokenBreakdown(input: 20, output: 6, cacheRead: 70))
    }

    func test_legacyTraceDBWithoutProcessUUIDStillReadsThreadIDUsage() {
        home = CodexTraceFixture.makeHome(rows: [])
        CodexTraceFixture.writeLegacyDBWithoutProcessUUID(at: home.appendingPathComponent("logs_2.sqlite"), rows: [
            .init(id: 1, ts: ts, threadId: "tLegacy",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 40, cached: 10, output: 5)),
        ])

        let events = CodexTraceReader(codexHome: home).read()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].sessionId, "tLegacy")
        XCTAssertEqual(events[0].tokens, TokenBreakdown(input: 30, output: 5, cacheRead: 10))
    }

    func test_correlatesNullThreadResponseCompletedByProcessUUID() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 10, ts: ts, threadId: nil, processUUID: "pid:2",
                  body: CodexTraceFixture.responseCompletedBody(model: "gpt-5.5", input: 100, cached: 80, output: 7),
                  target: "log"),
            .init(id: 11, ts: ts, threadId: "tCorrelated", processUUID: "pid:2",
                  body: "app-server turn turn_id=turnA model=gpt-5.5",
                  target: "codex_core::session::turn"),
        ])

        let events = CodexTraceReader(codexHome: home).read()
        XCTAssertEqual(events.map(\.sessionId), ["tCorrelated"])
        XCTAssertEqual(events.first?.tokens, TokenBreakdown(input: 20, output: 7, cacheRead: 80))
    }

    func test_parsesPostSamplingAsTotalOnly() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tSample", processUUID: "pid:3",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 123, turnId: "turn1"),
                  target: "codex_core::session::turn"),
        ])

        let events = CodexTraceReader(codexHome: home).read()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].sessionId, "tSample")
        XCTAssertEqual(events[0].model, "gpt-5.5")
        XCTAssertEqual(events[0].tokens, TokenBreakdown(totalOnly: 123))
        XCTAssertEqual(events[0].tokens.billable, 0)
    }

    func test_postSamplingUsesMaxPerTurn() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tSample", processUUID: "pid:3",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 50, turnId: "turn1"),
                  target: "codex_core::session::turn"),
            .init(id: 2, ts: ts, threadId: "tSample", processUUID: "pid:3",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 80, turnId: "turn1"),
                  target: "codex_core::session::turn"),
        ])

        let events = CodexTraceReader(codexHome: home).read()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].tokens, TokenBreakdown(totalOnly: 80))
    }

    func test_postSamplingExcludesRolloutThread() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tPersisted", processUUID: "pid:4",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 123, turnId: "turn1"),
                  target: "codex_core::session::turn"),
        ])
        CodexTraceFixture.addRollout(home: home, threadId: "tPersisted")
        XCTAssertTrue(CodexTraceReader(codexHome: home).read().isEmpty)
    }

    func test_postSamplingSecondReadEmitsOnlyDelta() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tSample", processUUID: "pid:5",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 50, turnId: "turn1"),
                  target: "codex_core::session::turn"),
        ])
        let reader = CodexTraceReader(codexHome: home)
        XCTAssertEqual(reader.read().first?.tokens, TokenBreakdown(totalOnly: 50))

        CodexTraceFixture.writeDB(at: home.appendingPathComponent("logs_2.sqlite"), rows: [
            .init(id: 1, ts: ts, threadId: "tSample", processUUID: "pid:5",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 50, turnId: "turn1"),
                  target: "codex_core::session::turn"),
            .init(id: 2, ts: ts, threadId: "tSample", processUUID: "pid:5",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 80, turnId: "turn1"),
                  target: "codex_core::session::turn"),
        ])

        XCTAssertEqual(reader.read().first?.tokens, TokenBreakdown(totalOnly: 30))
    }

    func test_exactUsageCanReplacePriorTotalOnly() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tSample", processUUID: "pid:6",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 80, turnId: "turn1"),
                  target: "codex_core::session::turn"),
        ])
        let reader = CodexTraceReader(codexHome: home)
        XCTAssertEqual(reader.read().first?.tokens, TokenBreakdown(totalOnly: 80))

        CodexTraceFixture.writeDB(at: home.appendingPathComponent("logs_2.sqlite"), rows: [
            .init(id: 1, ts: ts, threadId: "tSample", processUUID: "pid:6",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 80, turnId: "turn1"),
                  target: "codex_core::session::turn"),
            .init(id: 2, ts: ts, threadId: "tSample", processUUID: "pid:6",
                  body: CodexTraceFixture.responseCompletedBody(model: "gpt-5.5", input: 90, cached: 70, output: 6),
                  target: "log"),
        ])

        let replacement = reader.read().map(\.tokens)
        XCTAssertEqual(replacement, [
            TokenBreakdown(totalOnly: -80),
            TokenBreakdown(input: 20, output: 6, cacheRead: 70),
        ])
    }

    /// The retraction of a total-only estimate must be booked against the bucket
    /// it was CREDITED to, not the one the exact row happened to be read in. The
    /// two differ whenever the turn straddles an hour/day boundary or the exact
    /// row lands on a later poll — and a retraction stamped with the exact row's
    /// time would leave the original hour holding a positive total-only balance:
    /// a phantom "Headless (est.)" bar for a turn now counted as billable.
    func test_exactReplacement_retractsInTheOriginalBucket() {
        let laterTs = ts + 7_200   // two hours on — a different hourly bucket
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tSample", processUUID: "pid:6",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 80, turnId: "turn1"),
                  target: "codex_core::session::turn"),
        ])
        let reader = CodexTraceReader(codexHome: home)
        XCTAssertEqual(reader.read().first?.timestamp,
                       Date(timeIntervalSince1970: TimeInterval(ts)))

        CodexTraceFixture.writeDB(at: home.appendingPathComponent("logs_2.sqlite"), rows: [
            .init(id: 1, ts: ts, threadId: "tSample", processUUID: "pid:6",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 80, turnId: "turn1"),
                  target: "codex_core::session::turn"),
            .init(id: 2, ts: laterTs, threadId: "tSample", processUUID: "pid:6",
                  body: CodexTraceFixture.responseCompletedBody(model: "gpt-5.5", input: 90, cached: 70, output: 6),
                  target: "log"),
        ])

        let events = reader.read()
        XCTAssertEqual(events.map(\.tokens), [
            TokenBreakdown(totalOnly: -80),
            TokenBreakdown(input: 20, output: 6, cacheRead: 70),
        ])
        // The retraction lands on the ORIGINAL observation's clock, cancelling
        // the estimate exactly where it was booked…
        XCTAssertEqual(events[0].timestamp, Date(timeIntervalSince1970: TimeInterval(ts)))
        // …while the exact usage is credited where it actually happened.
        XCTAssertEqual(events[1].timestamp, Date(timeIntervalSince1970: TimeInterval(laterTs)))
    }

    /// `total_usage_tokens` is `active_context_tokens` — the size of the WHOLE
    /// context, cumulative across a thread's turns. Booking each turn's raw
    /// figure would re-count every earlier turn's context (turn 2's context
    /// contains turn 1's), inflating the estimate n-fold on a multi-turn thread.
    /// Only the growth is new consumption.
    func test_multiTurnThread_booksOnlyTheContextGrowth() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tMulti", processUUID: "pid:9",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 10_000, turnId: "turn1"),
                  target: "codex_core::session::turn"),
            .init(id: 2, ts: ts + 60, threadId: "tMulti", processUUID: "pid:9",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 25_000, turnId: "turn2"),
                  target: "codex_core::session::turn"),
            .init(id: 3, ts: ts + 120, threadId: "tMulti", processUUID: "pid:9",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 40_000, turnId: "turn3"),
                  target: "codex_core::session::turn"),
        ])
        let events = CodexTraceReader(codexHome: home).read()
        // Growth per turn — NOT 10k + 25k + 40k = 75k.
        XCTAssertEqual(events.map(\.tokens.totalOnly), [10_000, 15_000, 15_000])
        XCTAssertEqual(events.reduce(0) { $0 + $1.tokens.totalOnly }, 40_000)
    }

    /// Separate threads have separate contexts — one must not baseline the other.
    func test_separateThreads_doNotShareABaseline() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tA", processUUID: "pid:1",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 30_000, turnId: "turn1"),
                  target: "codex_core::session::turn"),
            .init(id: 2, ts: ts, threadId: "tB", processUUID: "pid:2",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 20_000, turnId: "turn1"),
                  target: "codex_core::session::turn"),
        ])
        let events = CodexTraceReader(codexHome: home).read()
        XCTAssertEqual(events.reduce(0) { $0 + $1.tokens.totalOnly }, 50_000)
    }

    /// Compaction shrinks the context window. That is not new consumption, and it
    /// must not book a negative estimate either.
    func test_contextShrink_booksNothing() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: ts, threadId: "tShrink", processUUID: "pid:7",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 50_000, turnId: "turn1"),
                  target: "codex_core::session::turn"),
            .init(id: 2, ts: ts + 60, threadId: "tShrink", processUUID: "pid:7",
                  body: CodexTraceFixture.postSamplingBody(model: "gpt-5.5", total: 12_000, turnId: "turn2"),
                  target: "codex_core::session::turn"),
        ])
        let events = CodexTraceReader(codexHome: home).read()
        XCTAssertEqual(events.map(\.tokens.totalOnly), [50_000])
    }

    func test_stateRestore_preservesCodexTraceTurnState() {
        let turn = ReaderState.CodexTraceTurn(
            precision: .totalOnly,
            timestamp: Date(timeIntervalSince1970: TimeInterval(ts)),
            model: "gpt-5.5",
            tokens: TokenBreakdown(totalOnly: 100)
        )
        let entry = ReaderState.Entry(
            offset: 9,
            mtime: Date(timeIntervalSince1970: 1),
            codexTraceTurns: ["thread#turn": turn]
        )
        let state = ReaderState(entries: ["/tmp/logs_2.sqlite": entry])
        let decoded = try! JSONDecoder().decode(ReaderState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded.entries["/tmp/logs_2.sqlite"]?.codexTraceTurns?["thread#turn"], turn)
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

    func test_discoveryError_preservesCursor_andDoesNotReingest() {
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: 1_781_481_600, threadId: "tA",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 10, cached: 0, output: 1)),
        ])
        let spy = SpyFileManager()
        let reader = CodexTraceReader(codexHome: home, fileManager: spy)
        XCTAssertEqual(reader.read().count, 1)                  // ingest id1, cursor advances
        XCTAssertFalse(reader.state().entries.isEmpty)
        spy.failContentsOfDirectory = true
        XCTAssertTrue(reader.read().isEmpty, "discovery error → skip")
        XCTAssertFalse(reader.state().entries.isEmpty, "cursor must NOT be wiped on discovery error")
        spy.failContentsOfDirectory = false
        XCTAssertTrue(reader.read().isEmpty, "recovered read must NOT re-ingest already-counted history")
    }

    func test_usageRowWithWhitespace_isNotSkipped() {
        // Valid usage JSON with a space after the colon — parseUsage tolerates it,
        // so the SQL gate must too (format-independent), or the row is lost.
        let spaced = #"turn{model=gpt-5.5}:run: "usage": {"input_tokens": 10, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 1, "total_tokens": 11}"#
        home = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: 1_781_481_600, threadId: "tA", body: spaced),
        ])
        let events = CodexTraceReader(codexHome: home).read()
        XCTAssertEqual(events.count, 1, "whitespace usage row must not be filtered out")
        XCTAssertEqual(events.first?.tokens.input, 10)
    }
}
