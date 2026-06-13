//
//  AntigravityCacheEvalFilterTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class AntigravityCacheEvalFilterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agyeval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ contents: String) throws -> String {
        let url = dir.appendingPathComponent("transcript.jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: data overload

    func test_data_withSignature_isEval() {
        let line = "{\"type\":\"USER_INPUT\",\"content\":\"You are a "
            + CacheEvaluationPrompts.activitySignature
            + " local cache folders for cleanup safety.\"}"
        XCTAssertTrue(AntigravityCacheEvalFilter.isCacheEvalTranscript(Data(line.utf8)))
    }

    func test_data_realUserSession_isNotEval() {
        let line = "{\"type\":\"USER_INPUT\",\"content\":\"Refactor the login view and add tests\"}"
        XCTAssertFalse(AntigravityCacheEvalFilter.isCacheEvalTranscript(Data(line.utf8)))
    }

    func test_data_empty_isNotEval() {
        XCTAssertFalse(AntigravityCacheEvalFilter.isCacheEvalTranscript(Data()))
    }

    // MARK: path overload (head read)

    func test_path_evalTranscript_isEval() throws {
        let path = try write(
            "{\"type\":\"USER_INPUT\",\"content\":\"You are a "
            + CacheEvaluationPrompts.activitySignature + " ...\"}\n"
            + "{\"type\":\"PLANNER_RESPONSE\",\"created_at\":\"2026-06-13T08:00:00Z\"}\n")
        XCTAssertTrue(AntigravityCacheEvalFilter.isCacheEvalTranscript(path: path))
    }

    func test_path_realSession_isNotEval() throws {
        let path = try write(
            "{\"type\":\"USER_INPUT\",\"content\":\"Fix the crash on launch\"}\n"
            + "{\"type\":\"PLANNER_RESPONSE\",\"created_at\":\"2026-06-13T08:00:00Z\"}\n")
        XCTAssertFalse(AntigravityCacheEvalFilter.isCacheEvalTranscript(path: path))
    }

    func test_path_missingFile_isNotEval() {
        let missing = dir.appendingPathComponent("nope.jsonl").path
        XCTAssertFalse(AntigravityCacheEvalFilter.isCacheEvalTranscript(path: missing))
    }

    /// The head read is bounded to avoid re-scanning large real transcripts. In
    /// practice the signature sits at the very start of the first line, so the
    /// default window always catches it; this documents that a signature pushed
    /// past the window is intentionally not seen.
    func test_path_headReadIsBounded() throws {
        let path = try write(
            String(repeating: "x", count: 64) + CacheEvaluationPrompts.activitySignature)
        XCTAssertFalse(AntigravityCacheEvalFilter.isCacheEvalTranscript(path: path, maxBytes: 16))
        XCTAssertTrue(AntigravityCacheEvalFilter.isCacheEvalTranscript(path: path))
    }
}
