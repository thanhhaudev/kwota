import XCTest
@testable import Kwota

final class CodexStatsReaderTests: XCTestCase {
    /// Retains every `TempDirectory` for the lifetime of the test method.
    /// `TempDirectory.deinit` removes its tree, so without holding the
    /// instance here the directory would be deleted as soon as `makeReader`
    /// returns — before `reader.read()` ever runs.
    private var tempDirs: [TempDirectory] = []
    override func tearDown() { tempDirs.removeAll() }

    private func makeReader(_ lines: [String], sub: String = "2026/05/20",
                            name: String = "rollout-2026-05-20T10-47-14-019e437e-a773-7b21-bd8b-9046bf8b5a29.jsonl")
        -> (CodexStatsReader, URL, URL) {
        let dir = TempDirectory()
        tempDirs.append(dir)
        let sessions = dir.url.appendingPathComponent("sessions")
        let fileDir = sessions.appendingPathComponent(sub)
        try! FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
        let file = fileDir.appendingPathComponent(name)
        try! (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return (CodexStatsReader(root: sessions), file, dir.url)
    }

    private let turnCtx = #"{"timestamp":"2026-05-20T03:47:15.888Z","type":"turn_context","payload":{"turn_id":"t1","model":"gpt-5.5"}}"#
    private func tokenCount(ts: String, input: Int, cached: Int, output: Int, reasoning: Int) -> String {
        let total = input + output
        return #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":999999,"cached_input_tokens":0,"output_tokens":999999,"reasoning_output_tokens":0,"total_tokens":1999998},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(total)},"model_context_window":258400}}}"#
    }

    func test_parsesLastTokenUsage_correctedMapping() {
        let (reader, _, _) = makeReader([
            turnCtx,
            tokenCount(ts: "2026-05-20T03:47:21.048Z", input: 16972, cached: 15744, output: 192, reasoning: 30),
        ])
        let events = reader.read()
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e.model, "gpt-5.5")
        XCTAssertEqual(e.tokens, TokenBreakdown(input: 1228, output: 192, cacheCreation: 0, cacheRead: 15744))
    }

    func test_usesPerTurnDelta_notCumulative_acrossEvents() {
        let (reader, _, _) = makeReader([
            turnCtx,
            tokenCount(ts: "2026-05-20T03:47:21.048Z", input: 1000, cached: 0, output: 100, reasoning: 0),
            tokenCount(ts: "2026-05-20T03:47:28.456Z", input: 2000, cached: 0, output: 200, reasoning: 0),
        ])
        let events = reader.read()
        XCTAssertEqual(events.map(\.tokens.input), [1000, 2000])
        XCTAssertEqual(events.map(\.tokens.output), [100, 200])
    }

    func test_skipsZeroTokenEvents() {
        let (reader, _, _) = makeReader([
            turnCtx,
            tokenCount(ts: "2026-05-20T03:47:21.048Z", input: 0, cached: 0, output: 0, reasoning: 0),
        ])
        XCTAssertTrue(reader.read().isEmpty)
    }

    func test_modelPersistsAcrossReadBoundary() {
        let dir = TempDirectory()
        let sessions = dir.url.appendingPathComponent("sessions/2026/05/20")
        try! FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-x.jsonl")
        try! (turnCtx + "\n").write(to: file, atomically: true, encoding: .utf8)
        let reader = CodexStatsReader(root: dir.url.appendingPathComponent("sessions"))
        XCTAssertTrue(reader.read().isEmpty)

        let handle = try! FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write((tokenCount(ts: "2026-05-20T03:47:21.048Z", input: 500, cached: 0, output: 50, reasoning: 0) + "\n").data(using: .utf8)!)
        try! handle.close()

        let events = reader.read()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].model, "gpt-5.5")
    }

    func test_incrementalDoesNotReEmit() {
        let (reader, _, _) = makeReader([
            turnCtx,
            tokenCount(ts: "2026-05-20T03:47:21.048Z", input: 1000, cached: 0, output: 100, reasoning: 0),
        ])
        XCTAssertEqual(reader.read().count, 1)
        XCTAssertEqual(reader.read().count, 0)
    }

    func test_rotationResetsOffsetAndModel() {
        let dir = TempDirectory(); tempDirs.append(dir)
        let sessionsRoot = dir.url.appendingPathComponent("sessions")
        let fileDir = sessionsRoot.appendingPathComponent("2026/05/20")
        try! FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
        let file = fileDir.appendingPathComponent("rollout-r.jsonl")
        let tc = { (i: Int) in self.tokenCount(ts: "2026-05-20T03:47:2\(i).000Z", input: 1000, cached: 0, output: 100, reasoning: 0) }

        // First generation: gpt-5.5, padded so the rewrite is strictly smaller.
        try! (([turnCtx, tc(1), tc(2), tc(3)].joined(separator: "\n")) + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let reader = CodexStatsReader(root: sessionsRoot)
        let first = reader.read()
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first.allSatisfy { $0.model == "gpt-5.5" }, true)

        // Atomic overwrite with a DIFFERENT model and fewer bytes → rotation reset.
        let ctxCodex = #"{"timestamp":"2026-05-20T04:00:00.000Z","type":"turn_context","payload":{"turn_id":"t2","model":"gpt-5.5-codex"}}"#
        try! (([ctxCodex, tokenCount(ts: "2026-05-20T04:00:01.000Z", input: 7, cached: 0, output: 1, reasoning: 0)].joined(separator: "\n")) + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let second = reader.read()
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].model, "gpt-5.5-codex")   // stale gpt-5.5 cleared on reset
        XCTAssertEqual(second[0].tokens.input, 7)
    }

    func test_mtimeChangeWithoutShrinkDoesNotReingest() {
        // A `touch` / backup-restore on a fully-read rollout (same size, same
        // content) must NOT re-read it — re-emitting token_count events would
        // permanently double-count, since the ledger has no per-event dedup.
        let (reader, file, _) = makeReader([
            turnCtx,
            tokenCount(ts: "2026-05-20T03:47:21.048Z", input: 100, cached: 0, output: 10, reasoning: 0),
        ])
        XCTAssertEqual(reader.read().count, 1)
        try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
                                               ofItemAtPath: file.path)
        XCTAssertTrue(reader.read().isEmpty, "a touched-but-unchanged rollout must not re-emit")
    }

    func test_fullReadPrunesCursorsForDeletedFiles() {
        // `state()` no longer stats per cursor; the full `read()` walk is what
        // drops cursors for vanished files, keeping the snapshot bounded.
        let (reader, file, _) = makeReader([
            turnCtx,
            tokenCount(ts: "2026-05-20T03:47:21.048Z", input: 100, cached: 0, output: 10, reasoning: 0),
        ])
        _ = reader.read()
        XCTAssertFalse(reader.state().entries.isEmpty)        // cursor recorded
        try! FileManager.default.removeItem(at: file)
        _ = reader.read()                                     // full walk prunes it
        XCTAssertTrue(reader.state().entries.isEmpty)         // cursor dropped
    }

    func test_rejectsRolloutInSiblingBackupDir() {
        // A `rollout-*.jsonl` under a sibling like `sessions-backup` must NOT be
        // read by a reader rooted at `sessions` — the prefix check has to reject
        // it rather than fold backup/synced history into the ledger.
        let dir = TempDirectory(); tempDirs.append(dir)
        let sessions = dir.url.appendingPathComponent("sessions")
        try! FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let backup = dir.url.appendingPathComponent("sessions-backup/2026/05/20")
        try! FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let backupFile = backup.appendingPathComponent("rollout-x.jsonl")
        try! (([turnCtx, tokenCount(ts: "2026-05-20T03:47:21.048Z", input: 100, cached: 0, output: 10, reasoning: 0)]
                .joined(separator: "\n")) + "\n")
            .write(to: backupFile, atomically: true, encoding: .utf8)

        let reader = CodexStatsReader(root: sessions)
        XCTAssertTrue(reader.read(only: [backupFile]).isEmpty)   // sibling dir rejected
    }

    func test_modelSurvivesStateRestoreRoundTrip() {
        let dir = TempDirectory(); tempDirs.append(dir)
        let sessionsRoot = dir.url.appendingPathComponent("sessions")
        let fileDir = sessionsRoot.appendingPathComponent("2026/05/20")
        try! FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
        let file = fileDir.appendingPathComponent("rollout-rt.jsonl")

        // First reader consumes only the turn_context (model recorded, no events).
        try! (turnCtx + "\n").write(to: file, atomically: true, encoding: .utf8)
        let reader1 = CodexStatsReader(root: sessionsRoot)
        XCTAssertTrue(reader1.read().isEmpty)
        let saved = reader1.state()
        XCTAssertEqual(saved.entries.values.first?.model, "gpt-5.5")   // model persisted into state

        // Append the turn's token_count, then a FRESH reader restores + resumes.
        let handle = try! FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write((tokenCount(ts: "2026-05-20T03:47:21.048Z", input: 500, cached: 0, output: 50, reasoning: 0) + "\n").data(using: .utf8)!)
        try! handle.close()

        let reader2 = CodexStatsReader(root: sessionsRoot)
        reader2.restore(saved)
        let events = reader2.read()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].model, "gpt-5.5")   // attribution survived persist + restart
    }
}
