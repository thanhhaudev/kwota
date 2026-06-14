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

    func test_transcriptAppend_debouncesToFullWalk() async {
        let transcript = "/Users/x/.gemini/antigravity/brain/abc/transcript.jsonl"
        let watcher = AntigravityStatsWatcher(makeFileEvents: makeStream([transcript]),
                                              pollInterval: 9999, debounce: 0.05)
        var calls: [Set<URL>?] = []
        watcher.onChangedPaths = { calls.append($0) }
        watcher.start()
        try? await Task.sleep(for: .seconds(0.2))
        // initial backfill (nil) + one debounced trigger (nil = full DB walk).
        XCTAssertGreaterThanOrEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0 == nil })
        watcher.stop()
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
