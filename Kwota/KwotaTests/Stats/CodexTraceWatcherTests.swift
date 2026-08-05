//  CodexTraceWatcherTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

@MainActor
final class CodexTraceWatcherTests: XCTestCase {
    private var home: URL!
    override func tearDown() { if let home { try? FileManager.default.removeItem(at: home) }; home = nil }

    private func makeHomeWithDB() -> URL {
        let h = CodexTraceFixture.makeHome(rows: [
            .init(id: 1, ts: 1_781_481_600, threadId: "tA",
                  body: CodexTraceFixture.usageBody(model: "gpt-5.5", input: 10, cached: 0, output: 1)),
        ])
        return h
    }

    func test_startFiresInitialBackfillWithSqlitePaths() {
        home = makeHomeWithDB()
        let watcher = CodexTraceWatcher(codexHome: home, pollInterval: 9999)
        let exp = expectation(description: "backfill")
        watcher.onChangedPaths = { paths in
            XCTAssertEqual(paths?.count, 1)
            XCTAssertEqual(paths?.first?.lastPathComponent, "logs_2.sqlite")
            exp.fulfill()
        }
        watcher.start()
        wait(for: [exp], timeout: 1)
        watcher.stop()
    }

    func test_pollFiresAgainOnInterval() {
        home = makeHomeWithDB()
        let watcher = CodexTraceWatcher(codexHome: home, pollInterval: 0.05)
        let exp = expectation(description: "two fires")
        exp.expectedFulfillmentCount = 2
        // The 0.05s poll keeps firing; we only assert it fired at least twice
        // (initial backfill + at least one poll). Without this, a 3rd fire that
        // lands before stop() over-fulfills and fails the test.
        exp.assertForOverFulfill = false
        watcher.onChangedPaths = { _ in exp.fulfill() }
        watcher.start()
        wait(for: [exp], timeout: 2)
        watcher.stop()
    }

    func test_noDBsMeansNoFire() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let watcher = CodexTraceWatcher(codexHome: home, pollInterval: 9999)
        // Inverted expectation: `start()`'s initial backfill now runs inside a
        // Task (the directory listing hops off-main via OffMain.run), so a
        // same-tick synchronous assertion right after start()/stop() would
        // pass trivially whether or not the Task ever ran — not because the
        // empty-directory path was genuinely exercised. Waiting briefly for
        // fulfillment gives the Task a real chance to fire before asserting
        // it didn't. Mirrors test_startFiresInitialBackfillWithSqlitePaths above.
        let exp = expectation(description: "no fire")
        exp.isInverted = true
        watcher.onChangedPaths = { _ in exp.fulfill() }
        watcher.start()
        wait(for: [exp], timeout: 0.3)
        watcher.stop()
    }
}
