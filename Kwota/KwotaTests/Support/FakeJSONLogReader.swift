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
    func read() -> [UsageEvent] {
        guard !queue.isEmpty else { return [] }
        return queue.removeFirst()
    }
    func lastSeenLine() -> String? { stubbedLastLine }
}
