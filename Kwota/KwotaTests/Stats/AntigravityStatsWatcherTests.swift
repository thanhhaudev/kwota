//  AntigravityStatsWatcherTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

@MainActor
final class AntigravityStatsWatcherTests: XCTestCase {

    private func makeStream(_ paths: [String]) -> () -> AsyncStream<String> {
        { AsyncStream { cont in for p in paths { cont.yield(p) }; cont.finish() } }
    }

    func test_start_firesInitialBackfillWithNil() async {
        let watcher = AntigravityStatsWatcher(makeFileEvents: makeStream([]), pollInterval: 9999, debounce: 0.01)
        var calls: [Set<URL>?] = []
        watcher.onChangedPaths = { calls.append($0) }
        watcher.start()
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls[0])   // initial backfill is nil (full walk)
        watcher.stop()
    }

    func test_start_isIdempotent() async {
        let watcher = AntigravityStatsWatcher(makeFileEvents: makeStream([]), pollInterval: 9999, debounce: 0.01)
        var calls = 0
        watcher.onChangedPaths = { _ in calls += 1 }
        watcher.start()
        watcher.start()   // second call must not re-fire / re-consume
        XCTAssertEqual(calls, 1)
        watcher.stop()
    }

    func test_transcriptAppend_debouncesToTargetedDBRead() async {
        let transcript = "/Users/x/.gemini/antigravity/brain/abc/.system_generated/logs/transcript.jsonl"
        let watcher = AntigravityStatsWatcher(makeFileEvents: makeStream([transcript]),
                                              pollInterval: 9999, debounce: 0.05)
        var calls: [Set<URL>?] = []
        watcher.onChangedPaths = { calls.append($0) }
        watcher.start()
        try? await Task.sleep(for: .seconds(0.2))
        // initial backfill (nil) + one debounced trigger targeting just abc.db.
        XCTAssertNil(calls.first ?? nil, "initial backfill is a full walk")
        XCTAssertEqual(calls.last,
                       Set([URL(fileURLWithPath: "/Users/x/.gemini/antigravity/conversations/abc.db")]),
                       "append maps to its conversation DB, not a full walk")
        watcher.stop()
    }

    func test_burstCoalescesMultipleConversationDBsIntoOneTargetedRead() async {
        let a = "/Users/x/.gemini/antigravity/brain/abc/.system_generated/logs/transcript.jsonl"
        let b = "/Users/x/.gemini/antigravity/brain/def/.system_generated/logs/transcript.jsonl"
        let watcher = AntigravityStatsWatcher(makeFileEvents: makeStream([a, b]),
                                              pollInterval: 9999, debounce: 0.05)
        var batches: [Set<URL>] = []
        watcher.onChangedPaths = { if let paths = $0 { batches.append(paths) } }

        watcher.start()
        try? await Task.sleep(for: .seconds(0.2))

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first, [
            URL(fileURLWithPath: "/Users/x/.gemini/antigravity/conversations/abc.db"),
            URL(fileURLWithPath: "/Users/x/.gemini/antigravity/conversations/def.db"),
        ])
        watcher.stop()
    }

    func test_conversationDB_mapsBrainTranscriptToConversationDB() {
        let ide = "/Users/x/.gemini/antigravity/brain/abc/.system_generated/logs/transcript.jsonl"
        XCTAssertEqual(AntigravityStatsWatcher.conversationDB(forTranscript: ide),
                       URL(fileURLWithPath: "/Users/x/.gemini/antigravity/conversations/abc.db"))
        let cli = "/Users/x/.gemini/antigravity-cli/brain/zzz/transcript.jsonl"
        XCTAssertEqual(AntigravityStatsWatcher.conversationDB(forTranscript: cli),
                       URL(fileURLWithPath: "/Users/x/.gemini/antigravity-cli/conversations/zzz.db"))
        // Not a brain transcript ⇒ nil ⇒ caller falls back to a full walk.
        XCTAssertNil(AntigravityStatsWatcher.conversationDB(forTranscript: "/Users/x/.gemini/other.jsonl"))
    }

    func test_nonTranscriptPath_isIgnored() async {
        let other = "/Users/x/.gemini/antigravity/brain/abc/notes.txt"
        let watcher = AntigravityStatsWatcher(makeFileEvents: makeStream([other]),
                                              pollInterval: 9999, debounce: 0.05)
        var calls = 0
        watcher.onChangedPaths = { _ in calls += 1 }
        watcher.start()
        try? await Task.sleep(for: .seconds(0.2))
        XCTAssertEqual(calls, 1)   // only the initial backfill
        watcher.stop()
    }
}
