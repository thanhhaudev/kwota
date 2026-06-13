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

    // MARK: - ReaderState snapshot/restore (Phase 2)

    func testStateAndRestore_roundTrip() throws {
        let tmp = TempDirectory()
        let projects = tmp.file("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let session = projects.appendingPathComponent("proj").appendingPathComponent("s1")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let file = session.appendingPathComponent("a.jsonl")
        try (assistantLine(uuid: "u1", ts: "2026-04-26T11:30:00Z") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let reader = FilesystemJSONLogReader(root: projects)
        _ = reader.read()                          // advance offsets
        let snapshot = reader.state()
        XCTAssertEqual(snapshot.entries.count, 1)
        // Stored path may resolve symlinks (e.g. /var → /private/var on macOS
        // temp dirs), so look up by basename rather than exact `file.path`.
        let only = snapshot.entries.first
        XCTAssertEqual((only?.key as NSString?)?.lastPathComponent, "a.jsonl")
        XCTAssertGreaterThan(only?.value.offset ?? 0, 0)

        let reader2 = FilesystemJSONLogReader(root: projects)
        reader2.restore(snapshot)
        let events = reader2.read()
        XCTAssertTrue(events.isEmpty, "restoring offset must mean read() emits no events for unchanged content")
    }

    func testState_prunesEntriesForDeletedFiles() throws {
        let tmp = TempDirectory()
        let projects = tmp.file("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let session = projects.appendingPathComponent("proj").appendingPathComponent("s1")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let file = session.appendingPathComponent("a.jsonl")
        try (assistantLine(uuid: "u1", ts: "2026-04-26T11:30:00Z") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let reader = FilesystemJSONLogReader(root: projects)
        _ = reader.read()
        XCTAssertEqual(reader.state().entries.count, 1)

        try FileManager.default.removeItem(at: file)
        let pruned = reader.state()
        XCTAssertEqual(pruned.entries.count, 0, "state() must drop entries for files no longer on disk")
    }

    func testStateIsCodable() throws {
        let s = ReaderState(entries: [
            "/tmp/a.jsonl": .init(offset: 1234, mtime: Date(timeIntervalSince1970: 1_700_000_000))
        ])
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(ReaderState.self, from: data)
        XCTAssertEqual(decoded, s)
    }

    // MARK: - read(only:) incremental

    func testReadOnly_emitsEventsForListedFileOnly() throws {
        let tmp = TempDirectory()
        let projects = tmp.file("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let session = projects.appendingPathComponent("proj").appendingPathComponent("s1")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let touched = session.appendingPathComponent("a.jsonl")
        let untouched = session.appendingPathComponent("b.jsonl")
        try (assistantLine(uuid: "u1", ts: "2026-04-26T11:30:00.000Z") + "\n")
            .write(to: touched, atomically: true, encoding: .utf8)
        try (assistantLine(uuid: "u2", ts: "2026-04-26T11:31:00.000Z") + "\n")
            .write(to: untouched, atomically: true, encoding: .utf8)

        let reader = FilesystemJSONLogReader(root: projects)
        let events = reader.read(only: [touched])
        XCTAssertEqual(events.map(\.uuid), ["u1"],
                       "read(only:) must emit only events for the named file")

        // The untouched file's offset is never advanced; a full read after
        // the incremental call still emits its content.
        let full = reader.read()
        XCTAssertEqual(full.map(\.uuid), ["u2"],
                       "full read after read(only:) must still process the file we skipped")
    }

    func testReadOnly_advancesOffsetForTouchedFile() throws {
        let tmp = TempDirectory()
        let projects = tmp.file("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let session = projects.appendingPathComponent("proj").appendingPathComponent("s1")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let file = session.appendingPathComponent("a.jsonl")
        try (assistantLine(uuid: "u1", ts: "2026-04-26T11:30:00.000Z") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let reader = FilesystemJSONLogReader(root: projects)
        let first = reader.read(only: [file])
        XCTAssertEqual(first.count, 1, "first incremental read emits the line")

        let second = reader.read(only: [file])
        XCTAssertEqual(second.count, 0,
                       "second incremental read on unchanged file emits nothing — offset advanced")
    }

    func testReadOnly_ignoresPathsOutsideRoot() throws {
        let tmp = TempDirectory()
        let projects = tmp.file("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        // A file that exists but lives outside `projects`. The reader must
        // refuse to touch it.
        let outside = tmp.file("outside.jsonl")
        try (assistantLine(uuid: "u-outside", ts: "2026-04-26T11:30:00.000Z") + "\n")
            .write(to: outside, atomically: true, encoding: .utf8)

        let reader = FilesystemJSONLogReader(root: projects)
        let events = reader.read(only: [outside])
        XCTAssertTrue(events.isEmpty,
                      "read(only:) must ignore paths whose prefix is not the watched root")
    }

    func test_parse_extractsModelFromAssistantLine() throws {
        let tmp = TempDirectory()
        let projectDir = tmp.file("p1")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let usage = #"{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}"#
        let line = #"{"type":"assistant","uuid":"u1","sessionId":"s1","timestamp":"2026-06-13T10:00:00.000Z","message":{"model":"claude-opus-4-8","usage":\#(usage)}}"#
        try (line + "\n").write(to: projectDir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        let reader = FilesystemJSONLogReader(root: tmp.url)
        let events = reader.read()

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.model, "claude-opus-4-8")
        XCTAssertEqual(events.first?.tokens.input, 10)
    }

    private func assistantLine(uuid: String, ts: String) -> String {
        """
        {"type":"assistant","uuid":"\(uuid)","sessionId":"s1","timestamp":"\(ts)","message":{"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }
}
