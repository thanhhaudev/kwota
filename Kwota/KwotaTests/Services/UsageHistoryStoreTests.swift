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
        let e1 = makeEntry(60)
        let e2 = makeEntry(30)
        try store.append(e1)
        try store.append(e2)
        try store.flushPendingWrite()
        XCTAssertEqual(try store.load(), [e1, e2])
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
        // trimming happens at 50.
        for i in 0..<55 {
            try store.append(UsageHistoryEntry(
                at: Date(timeIntervalSince1970: TimeInterval(3_000 + i)),
                fiveHour: 40,
                sevenDay: nil
            ))
        }
        XCTAssertEqual(try store.load().count, 50)

        suite.removePersistentDomain(forName: suiteName)
    }
}
