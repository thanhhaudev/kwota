//
//  FakeJSONLogReader.swift
//  KwotaTests
//

import Foundation
@testable import Kwota

// `@unchecked Sendable` to satisfy the `JSONLogReader: Sendable` requirement.
// Tests drive it from the main actor via the synchronous `tick()`, never the
// off-main `tickAsync` path, so its mutable queue is single-threaded in use.
final class FakeJSONLogReader: JSONLogReader, @unchecked Sendable {
    var queue: [[UsageEvent]] = []
    var stubbedLastLine: String?
    /// When set, `state()` returns this value verbatim — lets tests pretend
    /// the reader has advanced through some bytes without writing JSONL.
    var stateOverride: ReaderState?
    /// Captures whatever state `UsageMonitor.init` passes to `restore(_:)`,
    /// so tests can assert that the wiring is correct.
    private(set) var restoredState: ReaderState?

    func read() -> [UsageEvent] {
        guard !queue.isEmpty else { return [] }
        return queue.removeFirst()
    }
    func lastSeenLine() -> String? { stubbedLastLine }

    func state() -> ReaderState { stateOverride ?? ReaderState() }
    func restore(_ state: ReaderState) { restoredState = state }
}
