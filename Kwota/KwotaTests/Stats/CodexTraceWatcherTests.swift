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
        var fired = false
        watcher.onChangedPaths = { _ in fired = true }
        watcher.start()
        watcher.stop()
        XCTAssertFalse(fired, "no logs_*.sqlite -> nothing to read")
    }
}
