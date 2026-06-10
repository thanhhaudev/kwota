//
//  DebugReportExporterTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class DebugReportExporterTests: XCTestCase {

    private func sampleSnapshot() -> SystemSnapshot {
        SystemSnapshot(
            macOSVersion: "14.5.1",
            installedComponents: [
                InstalledComponent(id: "claude-cli", label: "Claude Code", version: "2.1.133")
            ]
        )
    }

    private func sampleEvent(
        time: TimeInterval = 0,
        session: String = "8c879b59-aaaa-4111-bbbb-cccccccccccc",
        input: Int = 1,
        output: Int = 165
    ) -> UsageEvent {
        UsageEvent(
            uuid: UUID().uuidString,
            sessionId: session,
            timestamp: Date(timeIntervalSince1970: time),
            tokens: TokenBreakdown(input: input, output: output)
        )
    }

    private func fixedDate() -> Date {
        Date(timeIntervalSince1970: 1_715_578_920) // 2024-05-13T05:42:00Z
    }

    func test_buildPayload_includesAllSections() {
        let s = DebugReportExporter.shared.buildPayload(
            events: [sampleEvent()],
            rawLine: "{\"type\":\"x\"}",
            logLines: ["[info] hi"],
            snapshot: sampleSnapshot(),
            appVersion: "1.0",
            now: fixedDate()
        )

        XCTAssertTrue(s.contains("System\n------\n"))
        XCTAssertTrue(s.contains("Recent Events (1)\n------------------\n"))
        XCTAssertTrue(s.contains("Last JSONL Line\n---------------\n"))
        XCTAssertTrue(s.contains("Log (last 1 lines)\n--------------------\n"))
        XCTAssertTrue(s.contains("Kwota: 1.0"))
        XCTAssertFalse(s.contains("Kwota: 1.0 ("))
        XCTAssertTrue(s.contains("macOS: 14.5.1"))
        XCTAssertTrue(s.contains("Claude Code: 2.1.133"))
    }

    func test_buildPayload_emptySources_renderNoneSentinels() {
        let s = DebugReportExporter.shared.buildPayload(
            events: [],
            rawLine: nil,
            logLines: [],
            snapshot: nil,
            appVersion: nil,
            now: fixedDate()
        )

        XCTAssertTrue(s.contains("System\n------\n(none)"))
        XCTAssertTrue(s.contains("Recent Events (0)\n------------------\n(none)"))
        XCTAssertTrue(s.contains("Last JSONL Line\n---------------\n(none)"))
        XCTAssertTrue(s.contains("Log (last 0 lines)\n--------------------\n(none)"))
    }

    func test_buildPayload_rawJSONLLine_isRedactedNotEmitted() {
        // Conversation lines from ~/.claude/projects/**/*.jsonl include
        // assistant `message.content` (code, pasted secrets). Export goes
        // to support tickets — assert content never reaches the payload
        // and the fingerprint replaces it.
        let secret = "{\"type\":\"assistant\",\"message\":{\"content\":\"BEGIN-SECRET-PASSWORD-12345\"}}"
        let s = DebugReportExporter.shared.buildPayload(
            events: [],
            rawLine: secret,
            logLines: [],
            snapshot: nil,
            appVersion: nil,
            now: fixedDate()
        )

        XCTAssertFalse(s.contains("BEGIN-SECRET-PASSWORD-12345"))
        XCTAssertFalse(s.contains("message"))
        XCTAssertFalse(s.contains("content"))
        XCTAssertTrue(s.contains("(redacted; \(secret.count) bytes; sha256:"))
    }

    func test_buildPayload_systemSection_omitsArchAndCliSuffix() {
        let s = DebugReportExporter.shared.buildPayload(
            events: [],
            rawLine: nil,
            logLines: [],
            snapshot: sampleSnapshot(),
            appVersion: "1.0",
            now: fixedDate()
        )

        XCTAssertFalse(s.contains("Apple Silicon"))
        XCTAssertFalse(s.contains("(Claude Code)"))
    }

    func test_buildPayload_generatedLine_usesInjectedDate() {
        let s = DebugReportExporter.shared.buildPayload(
            events: [],
            rawLine: nil,
            logLines: [],
            snapshot: nil,
            appVersion: nil,
            now: fixedDate()
        )

        XCTAssertTrue(s.contains("Generated: 2024-05-13T05:42:00Z"))
    }

    func test_defaultFilename_isTimestamped() {
        let name = DebugReportExporter.shared.defaultFilename(now: fixedDate())

        XCTAssertTrue(name.hasPrefix("kwota-debug-"))
        XCTAssertTrue(name.hasSuffix(".txt"))
        // body between prefix and suffix is yyyyMMdd-HHmmss (15 chars)
        let body = name.replacingOccurrences(of: "kwota-debug-", with: "")
                       .replacingOccurrences(of: ".txt", with: "")
        XCTAssertEqual(body.count, 15)
    }
}
