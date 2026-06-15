//  CodexCompositeReaderTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

/// Minimal in-memory reader to prove the composite merges + routes state.
private final class StubReader: JSONLogReader, @unchecked Sendable {
    let events: [UsageEvent]
    var restored: ReaderState?
    private let stateToReturn: ReaderState
    init(events: [UsageEvent], state: ReaderState) { self.events = events; self.stateToReturn = state }
    func read() -> [UsageEvent] { events }
    func read(only paths: Set<URL>) -> [UsageEvent] { events }
    func lastSeenLine() -> String? { nil }
    func state() -> ReaderState { stateToReturn }
    func restore(_ state: ReaderState) { restored = state }
}

final class CodexCompositeReaderTests: XCTestCase {
    private func ev(_ id: String) -> UsageEvent {
        UsageEvent(uuid: id, sessionId: id, timestamp: Date(timeIntervalSince1970: 0),
                   tokens: TokenBreakdown(input: 1), model: "gpt-5.5")
    }

    func test_readMergesBothSources() {
        let rollout = StubReader(events: [ev("roll")], state: ReaderState())
        let trace = StubReader(events: [ev("trace")], state: ReaderState())
        let c = CodexCompositeReader(rollout: rollout, trace: trace)
        XCTAssertEqual(Set(c.read().map(\.uuid)), ["roll", "trace"])
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
