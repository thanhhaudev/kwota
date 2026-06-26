//
//  UsageHistoryStoreTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class UsageHistoryStoreTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    private func makeEntry(_ secondsAgo: TimeInterval, fiveHour: Double? = 50, sevenDay: Double? = 60) -> UsageHistoryEntry {
        UsageHistoryEntry(at: Date(timeIntervalSinceNow: -secondsAgo),
                          fiveHour: fiveHour,
                          sevenDay: sevenDay)
    }

    func testLoadOnEmptyFileReturnsEmpty() throws {
        let store = UsageHistoryStore(historyFile: temp.file("h.json"))
        XCTAssertEqual(try store.load(), [])
    }

    func testAppendThenLoadRoundTrips() throws {
        let store = UsageHistoryStore(historyFile: temp.file("h.json"), writeDebounce: 0)
        // Distinct session readings stay distinct. The second entry repeats
        // the weekly value, so persistence drops that duplicate sevenDay
        // sample instead of burning the weekly retention cap.
        let e1 = makeEntry(60, fiveHour: 50, sevenDay: 60)
        let e2 = makeEntry(30, fiveHour: 55, sevenDay: 60)
        try store.append(e1)
        try store.append(e2)
        try store.flushPendingWrite()
        XCTAssertEqual(
            try store.load(),
            [e1, UsageHistoryEntry(id: e2.id, at: e2.at, fiveHour: 55, sevenDay: nil)]
        )
    }

    func testCapEnforcesSessionLimit() throws {
        let store = UsageHistoryStore(
            historyFile: temp.file("h.json"),
            sessionCap: 3,
            weeklyCap: 100,
            writeDebounce: 0
        )
        // 5 session-only entries (no sevenDay)
        for i in 0..<5 {
            try store.append(UsageHistoryEntry(
                at: Date(timeIntervalSinceNow: TimeInterval(i)),
                fiveHour: Double(i * 10),
                sevenDay: nil
            ))
        }
        try store.flushPendingWrite()
        let loaded = try store.load()
        let sessionEntries = loaded.filter { $0.fiveHour != nil && $0.sevenDay == nil }
        XCTAssertEqual(sessionEntries.count, 3)
        XCTAssertEqual(sessionEntries.map(\.fiveHour), [20.0, 30.0, 40.0]) // newest 3 retained
    }

    func testCapEnforcesWeeklyLimitIndependently() throws {
        let store = UsageHistoryStore(
            historyFile: temp.file("h.json"),
            sessionCap: 100,
            weeklyCap: 2,
            writeDebounce: 0
        )
        for i in 0..<4 {
            try store.append(UsageHistoryEntry(
                at: Date(timeIntervalSinceNow: TimeInterval(i)),
                fiveHour: nil,
                sevenDay: Double(i * 10)
            ))
        }
        try store.flushPendingWrite()
        let weeklyEntries = try store.load().filter { $0.fiveHour == nil && $0.sevenDay != nil }
        XCTAssertEqual(weeklyEntries.count, 2)
    }

    func testEntriesWithBothFieldsCountAgainstBothCaps() throws {
        let store = UsageHistoryStore(
            historyFile: temp.file("h.json"),
            sessionCap: 2,
            weeklyCap: 2,
            writeDebounce: 0
        )
        for i in 0..<4 {
            try store.append(UsageHistoryEntry(
                at: Date(timeIntervalSinceNow: TimeInterval(i)),
                fiveHour: Double(i),
                sevenDay: Double(i)
            ))
        }
        try store.flushPendingWrite()
        XCTAssertEqual(try store.load().count, 2) // 2 newest retained, both caps satisfied
    }

    func testRepeatedWeeklyValueDoesNotBurnWeeklyCapWhenSessionChanges() throws {
        let store = UsageHistoryStore(
            historyFile: temp.file("h.json"),
            sessionCap: 100,
            weeklyCap: 2,
            writeDebounce: 0
        )
        let base = Date(timeIntervalSince1970: 1_000)

        for i in 0..<5 {
            try store.append(UsageHistoryEntry(
                at: base.addingTimeInterval(TimeInterval(i)),
                fiveHour: Double(i),
                sevenDay: 42
            ))
        }
        try store.flushPendingWrite()

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 5, "session samples must still be retained")
        XCTAssertEqual(
            loaded.compactMap(\.sevenDay),
            [42],
            "unchanged weekly utilization should be stored once, not once per session refresh"
        )
    }

    func testRunLengthDedupFoldsIdenticalRunToTwoAnchors() throws {
        let store = UsageHistoryStore(historyFile: temp.file("h.json"), writeDebounce: 0)
        // Five identical readings 1s apart. First two stay as plateau
        // start + initial tail; samples 3-5 slide the tail's timestamp
        // forward without growing the array.
        let base = Date(timeIntervalSince1970: 1_000)
        var appended: [UsageHistoryEntry] = []
        for i in 0..<5 {
            let e = UsageHistoryEntry(
                at: base.addingTimeInterval(TimeInterval(i)),
                fiveHour: 50,
                sevenDay: 17
            )
            appended.append(e)
            try store.append(e)
        }
        try store.flushPendingWrite()

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first?.at, appended[0].at, "Plateau start anchor preserved")
        XCTAssertEqual(loaded.last?.at, appended[4].at, "Tail slid to latest sample's timestamp")
        XCTAssertEqual(loaded.last?.fiveHour, 50)
        XCTAssertEqual(loaded.last?.sevenDay, 17)
    }

    func testValueChangeStartsNewRunWithoutFolding() throws {
        let store = UsageHistoryStore(historyFile: temp.file("h.json"), writeDebounce: 0)
        // A-A-A-B-B-B pattern. Each run independently folds; together
        // they should produce 4 entries (2 anchors per plateau), with the
        // mid-stream change preserved.
        let base = Date(timeIntervalSince1970: 1_000)
        for i in 0..<3 {
            try store.append(UsageHistoryEntry(
                at: base.addingTimeInterval(TimeInterval(i)),
                fiveHour: 50,
                sevenDay: 17
            ))
        }
        for i in 0..<3 {
            try store.append(UsageHistoryEntry(
                at: base.addingTimeInterval(TimeInterval(10 + i)),
                fiveHour: 60,
                sevenDay: 17
            ))
        }
        try store.flushPendingWrite()

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 4)
        XCTAssertEqual(loaded.map(\.fiveHour), [50, 50, 60, 60])
    }

    func test_userDefaultsKey_overridesDefault() throws {
        let suiteName = "kwota.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.set(50, forKey: "general.usageHistory.sessionCap")
        suite.set(25, forKey: "general.usageHistory.weeklyCap")

        let store = UsageHistoryStore(
            historyFile: temp.file("h.json"),
            writeDebounce: 0,
            defaults: suite
        )

        // The store's resolved caps aren't directly readable, but we can
        // observe them by appending past 50 session entries and verifying
        // trimming happens at 50. Vary `fiveHour` per i so run-length
        // dedup doesn't fold the inserts into 2 anchors before the cap
        // fires; otherwise this would assert what dedup does, not what
        // the cap does.
        for i in 0..<55 {
            try store.append(UsageHistoryEntry(
                at: Date(timeIntervalSince1970: TimeInterval(3_000 + i)),
                fiveHour: Double(i),
                sevenDay: nil
            ))
        }
        XCTAssertEqual(try store.load().count, 50)

        suite.removePersistentDomain(forName: suiteName)
    }
}
