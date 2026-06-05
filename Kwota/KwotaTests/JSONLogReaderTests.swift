//
//  JSONLogReaderTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class JSONLogReaderTests: XCTestCase {
    private func line(uuid: String, sessionId: String, ts: String, type: String = "assistant",
                      input: Int = 10, output: Int = 5) -> String {
        let usage = #"{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}"#
        return #"{"type":"\#(type)","uuid":"\#(uuid)","sessionId":"\#(sessionId)","timestamp":"\#(ts)","message":{"usage":\#(usage)}}"#
    }

    func testFirstReadReturnsAllAssistantEventsWithUsage() throws {
        let tmp = TempDirectory()
        let projectDir = tmp.file("p1")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("session-1.jsonl")
        try [
            line(uuid: "a", sessionId: "s1", ts: "2026-04-26T10:00:00.000Z"),
            #"{"type":"user","uuid":"u","sessionId":"s1","timestamp":"2026-04-26T10:00:01.000Z"}"#,
            line(uuid: "b", sessionId: "s1", ts: "2026-04-26T10:00:02.000Z", input: 1, output: 2)
        ].joined(separator: "\n").appending("\n").data(using: .utf8)!.write(to: file)

        let reader = FilesystemJSONLogReader(root: tmp.url)
        let events = reader.read()

        XCTAssertEqual(events.map(\.uuid), ["a", "b"])
        XCTAssertEqual(events[0].sessionId, "s1")
        XCTAssertEqual(events[1].tokens.billable, 3)
    }

    func testSecondReadReturnsOnlyAppendedEvents() throws {
        let tmp = TempDirectory()
        let projectDir = tmp.file("p1")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("session-1.jsonl")
        try (line(uuid: "a", sessionId: "s1", ts: "2026-04-26T10:00:00.000Z") + "\n")
            .data(using: .utf8)!.write(to: file)

        let reader = FilesystemJSONLogReader(root: tmp.url)
        XCTAssertEqual(reader.read().count, 1)

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        try handle.write(contentsOf: (line(uuid: "b", sessionId: "s1", ts: "2026-04-26T10:00:01.000Z") + "\n").data(using: .utf8)!)
        try handle.close()

        let second = reader.read()
        XCTAssertEqual(second.map(\.uuid), ["b"])
    }

    func testFileTruncationResetsOffset() throws {
        let tmp = TempDirectory()
        let projectDir = tmp.file("p1")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("session-1.jsonl")
        try (line(uuid: "a", sessionId: "s1", ts: "2026-04-26T10:00:00.000Z") + "\n")
            .data(using: .utf8)!.write(to: file)

        let reader = FilesystemJSONLogReader(root: tmp.url)
        XCTAssertEqual(reader.read().count, 1)

        try (line(uuid: "c", sessionId: "s1", ts: "2026-04-26T10:00:02.000Z") + "\n")
            .data(using: .utf8)!.write(to: file) // overwrites; smaller content possible

        let second = reader.read()
        XCTAssertEqual(second.map(\.uuid), ["c"])
    }

    func testPartialFinalLineIsDeferredUntilNewlineArrives() throws {
        let tmp = TempDirectory()
        let projectDir = tmp.file("p1")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("session-1.jsonl")

        let complete = line(uuid: "a", sessionId: "s1", ts: "2026-04-26T10:00:00.000Z")
        let partial  = line(uuid: "b", sessionId: "s1", ts: "2026-04-26T10:00:01.000Z")
        try (complete + "\n" + partial).data(using: .utf8)!.write(to: file)

        let reader = FilesystemJSONLogReader(root: tmp.url)
        XCTAssertEqual(reader.read().map(\.uuid), ["a"], "partial trailing line is ignored")

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        XCTAssertEqual(reader.read().map(\.uuid), ["b"])
    }

    func testDiscoversSubagentJSONLNestedUnderProject() throws {
        // Mirrors the real layout Claude Code uses for delegated subagent
        // sessions: <project>/<sessionId>/subagents/agent-*.jsonl. Without
        // recursion the reader would only emit "parent" and miss every
        // assistant turn produced inside the subagent.
        let tmp = TempDirectory()
        let projectDir = tmp.file("p1")
        let subagentDir = projectDir
            .appendingPathComponent("c1836ea2-2aea-4408-a9e6-545d90ba6f97")
            .appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)

        let parentFile = projectDir.appendingPathComponent("session-1.jsonl")
        try (line(uuid: "parent", sessionId: "s1", ts: "2026-04-26T10:00:00.000Z") + "\n")
            .data(using: .utf8)!.write(to: parentFile)

        let subagentFile = subagentDir.appendingPathComponent("agent-aaa.jsonl")
        try (line(uuid: "child", sessionId: "s1", ts: "2026-04-26T10:00:30.000Z") + "\n")
            .data(using: .utf8)!.write(to: subagentFile)

        let reader = FilesystemJSONLogReader(root: tmp.url)
        let uuids = Set(reader.read().map(\.uuid))
        XCTAssertEqual(uuids, ["parent", "child"])
    }

    func testLastSeenLineCapturesRawJSONL() throws {
        let tmp = TempDirectory()
        let projectDir = tmp.file("p1")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("session-1.jsonl")
        let only = line(uuid: "a", sessionId: "s1", ts: "2026-04-26T10:00:00.000Z")
        try (only + "\n").data(using: .utf8)!.write(to: file)

        let reader = FilesystemJSONLogReader(root: tmp.url)
        _ = reader.read()
        XCTAssertEqual(reader.lastSeenLine(), only)
    }
}
