//
//  ProviderActivityScannerTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class ProviderActivityScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ rel: String, _ contents: String, mtime: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    // A scanner pointed at the temp tree, parsing a top-level "timestamp" field.
    private func codexLikeScanner() -> ProviderActivityScanner {
        ProviderActivityScanner(
            provider: .codex,
            roots: [root],
            matchesFile: { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" },
            timestamp: { data in
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let s = obj["timestamp"] as? String else { return nil }
                return ProviderActivityBackfill.parseDate(s)
            }
        )
    }

    func test_scan_parsesInWindowTimestamps() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let cutoff = now.addingTimeInterval(-24 * 3600)
        let recent = now.addingTimeInterval(-3600)        // in window
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        _ = try write("2026/05/31/rollout-a.jsonl",
                      "{\"timestamp\":\"\(iso.string(from: recent))\",\"type\":\"response_item\"}\n")

        let dates = ProviderActivityBackfill.scan(codexLikeScanner(), cutoff: cutoff)
        XCTAssertEqual(dates.count, 1)
        XCTAssertEqual(dates[0].timeIntervalSince1970, recent.timeIntervalSince1970, accuracy: 1)
    }

    func test_scan_dropsOutOfWindowLines() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let cutoff = now.addingTimeInterval(-24 * 3600)
        let old = now.addingTimeInterval(-48 * 3600)      // out of window
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Recent mtime so the file is read, but its single line is out-of-window.
        _ = try write("2026/05/29/rollout-b.jsonl",
                      "{\"timestamp\":\"\(iso.string(from: old))\"}\n", mtime: now)

        let dates = ProviderActivityBackfill.scan(codexLikeScanner(), cutoff: cutoff)
        XCTAssertTrue(dates.isEmpty)
    }

    func test_scan_skipsFilesWithOldMtime() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let cutoff = now.addingTimeInterval(-24 * 3600)
        let old = now.addingTimeInterval(-48 * 3600)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Line timestamp is recent, but mtime is old → file is skipped entirely.
        _ = try write("rollout-c.jsonl",
                      "{\"timestamp\":\"\(iso.string(from: now.addingTimeInterval(-60)))\"}\n",
                      mtime: old)

        let dates = ProviderActivityBackfill.scan(codexLikeScanner(), cutoff: cutoff)
        XCTAssertTrue(dates.isEmpty)
    }

    func test_scan_ignoresNonMatchingFiles() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let cutoff = now.addingTimeInterval(-24 * 3600)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        _ = try write("notes.txt", "{\"timestamp\":\"\(iso.string(from: now))\"}\n")
        _ = try write("history.json", "{\"timestamp\":\"\(iso.string(from: now))\"}\n")

        let dates = ProviderActivityBackfill.scan(codexLikeScanner(), cutoff: cutoff)
        XCTAssertTrue(dates.isEmpty)
    }

    func test_parseDate_handlesFractionalAndPlain() {
        XCTAssertNotNil(ProviderActivityBackfill.parseDate("2026-05-31T06:34:41.983Z"))  // Codex
        XCTAssertNotNil(ProviderActivityBackfill.parseDate("2026-05-31T06:22:29Z"))      // Antigravity
        XCTAssertNil(ProviderActivityBackfill.parseDate("not-a-date"))
    }

    func test_codexFactory_rootsFromHome() throws {
        // A temp "home" with .codex/sessions present → scanner roots point at it.
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        let scanner = ProviderActivityBackfill.codex(home: home)
        XCTAssertEqual(scanner.provider, .codex)
        XCTAssertEqual(scanner.roots.map(\.path), [home.appendingPathComponent(".codex/sessions").path])
    }

    func test_antigravityFactory_emptyRootsWhenAbsent() throws {
        let home = root.appendingPathComponent("empty-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let scanner = ProviderActivityBackfill.antigravity(home: home)
        XCTAssertTrue(scanner.roots.isEmpty)   // no ~/.gemini → nothing to watch
    }

    // MARK: agent-response discriminator (factory closures)

    func test_codexFactory_countsAssistantRepliesOnly_perTurn() throws {
        let home = root.appendingPathComponent("ch", isDirectory: true)
        let dir = home.appendingPathComponent(".codex/sessions/2026/05/31")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let ts = iso.string(from: now.addingTimeInterval(-600))
        // A single Codex turn writes ONE assistant message plus N tool calls
        // (and possibly internal reasoning) — Codex's rollout JSONL splits a
        // turn into multiple `response_item` lines, whereas Claude writes a
        // turn as a single `type=="assistant"` record and Antigravity writes
        // one `PLANNER_RESPONSE`. Counting the tool calls here would inflate
        // Codex's wave by N× relative to the other providers' for the same
        // amount of user-visible work, so only the assistant message counts.
        let lines = [
            // Counted — the assistant's text reply (one per turn):
            "{\"timestamp\":\"\(ts)\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\"}}",
            // Not counted — tool CALLS the model issued during this same turn:
            "{\"timestamp\":\"\(ts)\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\"}}",
            "{\"timestamp\":\"\(ts)\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\"}}",
            "{\"timestamp\":\"\(ts)\",\"type\":\"response_item\",\"payload\":{\"type\":\"web_search_call\"}}",
            // Not counted — tool RESULT (a `_call_output`), internal reasoning,
            // user message, and a non-`response_item` event:
            "{\"timestamp\":\"\(ts)\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\"}}",
            "{\"timestamp\":\"\(ts)\",\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\"}}",
            "{\"timestamp\":\"\(ts)\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\"}}",
            "{\"timestamp\":\"\(ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\"}}",
        ].joined(separator: "\n") + "\n"
        try lines.write(to: dir.appendingPathComponent("rollout-x.jsonl"),
                        atomically: true, encoding: .utf8)

        let scanner = ProviderActivityBackfill.codex(home: home)
        let dates = ProviderActivityBackfill.scan(scanner, cutoff: now.addingTimeInterval(-24 * 3600))
        XCTAssertEqual(dates.count, 1)   // assistant message only — per-turn unit
    }

    func test_antigravityFactory_countsOnlyPlannerResponses() throws {
        let home = root.appendingPathComponent("ah", isDirectory: true)
        let dir = home.appendingPathComponent(".gemini/antigravity/brain/abc/.system_generated/logs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let ts = iso.string(from: now.addingTimeInterval(-600))
        let lines = [
            "{\"created_at\":\"\(ts)\",\"type\":\"PLANNER_RESPONSE\"}",
            "{\"created_at\":\"\(ts)\",\"type\":\"USER_INPUT\"}",
            "{\"created_at\":\"\(ts)\",\"type\":\"EPHEMERAL_MESSAGE\"}",
            "{\"created_at\":\"\(ts)\",\"type\":\"CONVERSATION_HISTORY\"}",
        ].joined(separator: "\n") + "\n"
        try lines.write(to: dir.appendingPathComponent("transcript.jsonl"),
                        atomically: true, encoding: .utf8)

        let scanner = ProviderActivityBackfill.antigravity(home: home)
        let dates = ProviderActivityBackfill.scan(scanner, cutoff: now.addingTimeInterval(-24 * 3600))
        XCTAssertEqual(dates.count, 1)   // only the PLANNER_RESPONSE row
    }
}
