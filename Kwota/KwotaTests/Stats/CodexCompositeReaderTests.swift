//  CodexCompositeReaderTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

/// Minimal in-memory reader to prove the composite merges + routes state.
private final class StubReader: JSONLogReader, @unchecked Sendable {
    let events: [UsageEvent]
    var restored: ReaderState?
    private(set) var readCount = 0
    private(set) var readOnlyCount = 0
    private let stateToReturn: ReaderState
    init(events: [UsageEvent], state: ReaderState) { self.events = events; self.stateToReturn = state }
    func read() -> [UsageEvent] { readCount += 1; return events }
    func read(only paths: Set<URL>) -> [UsageEvent] { readOnlyCount += 1; return events }
    func lastSeenLine() -> String? { nil }
    func state() -> ReaderState { stateToReturn }
    func restore(_ state: ReaderState) { restored = state }
}

final class CodexCompositeReaderTests: XCTestCase {
    private func ev(_ id: String) -> UsageEvent {
        UsageEvent(uuid: id, sessionId: id, timestamp: Date(timeIntervalSince1970: 0),
                   tokens: TokenBreakdown(input: 1), model: "gpt-5.5")
    }

    // A `nil` (full-walk) read for `.codex` only ever originates from the rollout
    // backstop watcher; the trace reader is driven exclusively by CodexTraceWatcher's
    // path-based reads. So `read()` must touch rollout only — never open the trace DB.
    func test_readReadsRolloutOnlyNeverTouchesTrace() {
        let rollout = StubReader(events: [ev("roll")], state: ReaderState())
        let trace = StubReader(events: [ev("trace")], state: ReaderState())
        let c = CodexCompositeReader(rollout: rollout, trace: trace)
        XCTAssertEqual(Set(c.read().map(\.uuid)), ["roll"])
        XCTAssertEqual(rollout.readCount, 1)
        XCTAssertEqual(trace.readCount, 0, "nil full-walk must not open the trace DB")
    }

    // The incremental path still routes to both sub-readers so trace usage is
    // ingested when CodexTraceWatcher supplies its `logs_*.sqlite` paths.
    func test_readOnlyRoutesToBothSources() {
        let rollout = StubReader(events: [ev("roll")], state: ReaderState())
        let trace = StubReader(events: [ev("trace")], state: ReaderState())
        let c = CodexCompositeReader(rollout: rollout, trace: trace)
        let merged = c.read(only: [URL(fileURLWithPath: "/home/.codex/logs_1.sqlite")])
        XCTAssertEqual(Set(merged.map(\.uuid)), ["roll", "trace"])
        XCTAssertEqual(rollout.readOnlyCount, 1)
        XCTAssertEqual(trace.readOnlyCount, 1)
    }

    func test_stateUnionThenRestoreSplitsByPath() {
        let rolloutState = ReaderState(entries: [
            "/home/.codex/sessions/x/rollout-2026-06-15T10-00-00-aaaa.jsonl":
                .init(offset: 10, mtime: .distantPast)])
        let traceState = ReaderState(entries: [
            "/home/.codex/logs_2.sqlite": .init(offset: 99, mtime: .distantPast)])
        let rollout = StubReader(events: [], state: rolloutState)
        let trace = StubReader(events: [], state: traceState)
        let c = CodexCompositeReader(rollout: rollout, trace: trace)

        // state() is the union of both
        let union = c.state()
        XCTAssertEqual(union.entries.count, 2)

        // restore() routes each entry back to its owner
        c.restore(union)
        XCTAssertEqual(rollout.restored?.entries.keys.first, "/home/.codex/sessions/x/rollout-2026-06-15T10-00-00-aaaa.jsonl")
        XCTAssertEqual(trace.restored?.entries.keys.first, "/home/.codex/logs_2.sqlite")
        XCTAssertEqual(rollout.restored?.entries.count, 1)
        XCTAssertEqual(trace.restored?.entries.count, 1)
    }
}
