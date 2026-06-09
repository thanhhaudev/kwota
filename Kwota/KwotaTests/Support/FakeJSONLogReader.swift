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
    /// Captures the path filter that `UsageMonitor` last passed to
    /// `read(only:)`. nil ⇒ the production code used the full-walk
    /// `read()` instead. Cleared on every `read()` call.
    private(set) var lastReadOnlyPaths: Set<URL>?
    /// Append-only log of every `read(only:)` call's path set. Lets tests
    /// assert ordered behavior across multiple iterations of `tickAsync`'s
    /// deferred-paths loop without dropping intermediate state the way
    /// `lastReadOnlyPaths` does.
    private(set) var readOnlyHistory: [Set<URL>] = []
    /// Count of full-walk `read()` calls.
    private(set) var readFullCount: Int = 0

    func read() -> [UsageEvent] {
        lastReadOnlyPaths = nil
        readFullCount += 1
        guard !queue.isEmpty else { return [] }
        return queue.removeFirst()
    }
    func read(only paths: Set<URL>) -> [UsageEvent] {
        lastReadOnlyPaths = paths
        readOnlyHistory.append(paths)
        guard !queue.isEmpty else { return [] }
        return queue.removeFirst()
    }
    func lastSeenLine() -> String? { stubbedLastLine }

    func state() -> ReaderState { stateOverride ?? ReaderState() }
    func restore(_ state: ReaderState) { restoredState = state }
}
