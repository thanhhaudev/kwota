import XCTest
@testable import Kwota

@MainActor
final class CodexStatsWatcherTests: XCTestCase {
    func test_filtersToRolloutPaths_andDebounces() async {
        let (stream, cont) = AsyncStream.makeStream(of: String.self)
        let watcher = CodexStatsWatcher(makeFileEvents: { stream }, pollInterval: 9999, debounce: 0.05)
        var batches: [Set<URL>?] = []
        watcher.onChangedPaths = { batches.append($0) }
        watcher.start()
        cont.yield("/Users/x/.codex/sessions/2026/06/13/rollout-a.jsonl")
        cont.yield("/Users/x/.codex/logs_42.sqlite-wal")              // filtered out
        cont.yield("/Users/x/.codex/sessions/2026/06/13/notes.txt")  // filtered out
        try? await Task.sleep(for: .milliseconds(150))
        watcher.stop()

        XCTAssertEqual(batches.first, .some(.none))   // first emit is the nil backfill
        let pathBatch = batches.compactMap { $0 }.first
        XCTAssertEqual(pathBatch, [URL(fileURLWithPath: "/Users/x/.codex/sessions/2026/06/13/rollout-a.jsonl")])
    }

    func test_emitsInitialBackfillOnStart() async {
        let (stream, _) = AsyncStream.makeStream(of: String.self)
        let watcher = CodexStatsWatcher(makeFileEvents: { stream }, pollInterval: 9999, debounce: 0.05)
        var got: [Set<URL>?] = []
        watcher.onChangedPaths = { got.append($0) }
        watcher.start()
        try? await Task.sleep(for: .milliseconds(20))
        watcher.stop()
        XCTAssertEqual(got.count, 1)
        XCTAssertNil(got[0])    // nil = full incremental walk for backfill
    }

    func test_burstCoalescesIntoOneBatch() async {
        let (stream, cont) = AsyncStream.makeStream(of: String.self)
        let watcher = CodexStatsWatcher(makeFileEvents: { stream }, pollInterval: 9999, debounce: 0.05)
        var pathBatches: [Set<URL>] = []
        watcher.onChangedPaths = { if let p = $0 { pathBatches.append(p) } }
        watcher.start()
        cont.yield("/Users/x/.codex/sessions/2026/06/13/rollout-a.jsonl")
        cont.yield("/Users/x/.codex/sessions/2026/06/13/rollout-b.jsonl")
        try? await Task.sleep(for: .milliseconds(150))
        watcher.stop()

        XCTAssertEqual(pathBatches.count, 1)   // the burst debounced into a single emit
        XCTAssertEqual(pathBatches.first, [
            URL(fileURLWithPath: "/Users/x/.codex/sessions/2026/06/13/rollout-a.jsonl"),
            URL(fileURLWithPath: "/Users/x/.codex/sessions/2026/06/13/rollout-b.jsonl"),
        ])
    }

    func test_stopCancelsPendingFlush() async {
        let (stream, cont) = AsyncStream.makeStream(of: String.self)
        let watcher = CodexStatsWatcher(makeFileEvents: { stream }, pollInterval: 9999, debounce: 0.2)
        var pathBatches: [Set<URL>] = []
        watcher.onChangedPaths = { if let p = $0 { pathBatches.append(p) } }
        watcher.start()
        cont.yield("/Users/x/.codex/sessions/2026/06/13/rollout-a.jsonl")
        try? await Task.sleep(for: .milliseconds(20))   // shorter than the 200ms debounce
        watcher.stop()                                  // cancels the pending flush
        try? await Task.sleep(for: .milliseconds(250))  // past when the flush would have fired
        XCTAssertTrue(pathBatches.isEmpty)              // no path batch ever emitted
    }
}
