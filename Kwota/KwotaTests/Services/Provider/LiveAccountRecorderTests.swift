//
//  LiveAccountRecorderTests.swift
//

import XCTest
@testable import Kwota

@MainActor
final class LiveAccountRecorderTests: XCTestCase {

    // MARK: stub fetcher

    private final class StubFetcher: ProfileUsageFetching {
        var byProfile: [UUID: Result<ProviderUsageSummary, Error>] = [:]
        private(set) var fetchCount = 0
        func fetch(profile: Profile) async throws -> ProviderUsageSummary {
            fetchCount += 1
            switch byProfile[profile.id] ?? .failure(StubError.unset) {
            case .success(let s): return s
            case .failure(let e): throw e
            }
        }
        enum StubError: Error { case unset }
    }

    private func claude(_ id: UUID = UUID(), kind: ProfileKind = .auto) -> Profile {
        Profile(id: id, name: "c", authMethod: .cliSync, providerID: .claude, email: "c@x.com")
            .with(kind: kind)
    }

    private func summary(_ provider: ProviderID, five: Double?, seven: Double?,
                         at: Date = Date(timeIntervalSince1970: 5_000)) -> ProviderUsageSummary {
        ProviderUsageSummary(
            providerID: provider, fetchedAt: at,
            primary: UsageBucket(utilization: five, resetsAt: nil),
            secondary: UsageBucket(utilization: seven, resetsAt: nil),
            payload: 0)
    }

    // MARK: tests

    func test_record_writesEntryToProfileFile() async throws {
        let tmp = TempDirectory()
        let p = claude()
        let fetcher = StubFetcher()
        fetcher.byProfile[p.id] = .success(summary(.claude, five: 10, seven: 20))
        let rec = LiveAccountRecorder(
            fetcher: fetcher,
            historyFile: { _ in tmp.file("usage-history.json") },
            now: { Date(timeIntervalSince1970: 10_000) })

        let wrote = await rec.record(profile: p, backoffUntil: nil, isStillNonActive: { true })

        XCTAssertTrue(wrote)
        let store = UsageHistoryStore(historyFile: tmp.file("usage-history.json"))
        let entries = try store.load()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.sevenDay ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(entries.first?.fiveHour ?? -1, 10, accuracy: 0.001)
    }

    func test_record_skipsWhenInBackoff() async {
        let tmp = TempDirectory()
        let p = claude()
        let fetcher = StubFetcher()
        fetcher.byProfile[p.id] = .success(summary(.claude, five: 10, seven: 20))
        let rec = LiveAccountRecorder(
            fetcher: fetcher,
            historyFile: { _ in tmp.file("usage-history.json") },
            now: { Date(timeIntervalSince1970: 10_000) })

        let wrote = await rec.record(
            profile: p,
            backoffUntil: Date(timeIntervalSince1970: 10_060),  // 60s in the future
            isStillNonActive: { true })

        XCTAssertFalse(wrote)
        XCTAssertEqual(fetcher.fetchCount, 0)
    }

    func test_record_skipsWhenRecentSampleWithinWindow() async throws {
        let tmp = TempDirectory()
        let p = claude()
        // Pre-seed a sample 10s before "now" (inside the 45s window).
        let seed = UsageHistoryStore(historyFile: tmp.file("usage-history.json"))
        try seed.append(UsageHistoryEntry(at: Date(timeIntervalSince1970: 9_990),
                                          fiveHour: 1, sevenDay: 2))
        try seed.flushPendingWrite()
        let fetcher = StubFetcher()
        fetcher.byProfile[p.id] = .success(summary(.claude, five: 10, seven: 20))
        let rec = LiveAccountRecorder(
            fetcher: fetcher,
            historyFile: { _ in tmp.file("usage-history.json") },
            now: { Date(timeIntervalSince1970: 10_000) })

        let wrote = await rec.record(profile: p, backoffUntil: nil, isStillNonActive: { true })

        XCTAssertFalse(wrote)
        XCTAssertEqual(fetcher.fetchCount, 0)
    }

    func test_record_dropsWriteWhenProfileBecameActive() async throws {
        let tmp = TempDirectory()
        let p = claude()
        let fetcher = StubFetcher()
        fetcher.byProfile[p.id] = .success(summary(.claude, five: 10, seven: 20))
        let rec = LiveAccountRecorder(
            fetcher: fetcher,
            historyFile: { _ in tmp.file("usage-history.json") },
            now: { Date(timeIntervalSince1970: 10_000) })

        let wrote = await rec.record(profile: p, backoffUntil: nil, isStillNonActive: { false })

        XCTAssertFalse(wrote)
        let store = UsageHistoryStore(historyFile: tmp.file("usage-history.json"))
        XCTAssertTrue((try store.load()).isEmpty)
    }

    func test_record_dropsEmptySummary() async throws {
        let tmp = TempDirectory()
        let p = claude()
        let fetcher = StubFetcher()
        fetcher.byProfile[p.id] = .success(summary(.claude, five: nil, seven: nil))
        let rec = LiveAccountRecorder(
            fetcher: fetcher,
            historyFile: { _ in tmp.file("usage-history.json") },
            now: { Date(timeIntervalSince1970: 10_000) })

        let wrote = await rec.record(profile: p, backoffUntil: nil, isStillNonActive: { true })

        XCTAssertFalse(wrote)
        let store = UsageHistoryStore(historyFile: tmp.file("usage-history.json"))
        XCTAssertTrue((try store.load()).isEmpty)
    }

    func test_liveNonActiveProfiles_onePerProvider_excludesActive() {
        let activeId = UUID()
        let claudeActive = Profile(id: activeId, name: "ca", authMethod: .cliSync,
                                   providerID: .claude, email: "ca@x.com")
        let codex = Profile(id: UUID(), name: "co", authMethod: .cliSync,
                            providerID: .codex, email: "co@x.com")
        let codexArchived = Profile(id: UUID(), name: "cx", authMethod: .cliSync,
                                    providerID: .codex, email: "cx@x.com").with(kind: .archived)
        let ag = Profile(id: UUID(), name: "ag", authMethod: .cliSync,
                         providerID: .antigravity, email: "ag@x.com")

        let out = LiveAccountRecorder.liveNonActiveProfiles(
            [claudeActive, codex, codexArchived, ag], activeProfileID: activeId)

        XCTAssertEqual(Set(out.map(\.providerID)), [.codex, .antigravity])
        XCTAssertFalse(out.contains { $0.id == activeId })
        XCTAssertFalse(out.contains { $0.id == codexArchived.id })
    }

    func test_recordNonActive_fetchesEachNonActiveLiveProvider() async throws {
        let tmp = TempDirectory()
        let activeId = UUID()
        let claudeActive = Profile(id: activeId, name: "ca", authMethod: .cliSync,
                                   providerID: .claude, email: "ca@x.com")
        let codex = Profile(id: UUID(), name: "co", authMethod: .cliSync,
                            providerID: .codex, email: "co@x.com")
        let fetcher = StubFetcher()
        fetcher.byProfile[codex.id] = .success(summary(.codex, five: 3, seven: 7))
        let rec = LiveAccountRecorder(
            fetcher: fetcher,
            historyFile: { id in tmp.file("h-\(id.uuidString).json") },
            now: { Date(timeIntervalSince1970: 10_000) })

        await rec.recordNonActive(
            profiles: [claudeActive, codex],
            currentActiveID: { activeId },
            backoffUntil: { _ in nil })

        XCTAssertEqual(fetcher.fetchCount, 1)  // only codex, never the active claude
        let store = UsageHistoryStore(historyFile: tmp.file("h-\(codex.id.uuidString).json"))
        XCTAssertEqual(try store.load().first?.sevenDay ?? -1, 7, accuracy: 0.001)
    }
}

/// Local helper: copy a Profile with a different kind (no public `kind` setter
/// pattern in tests; `Profile` is a value type so this is a plain field copy).
private extension Profile {
    func with(kind: ProfileKind) -> Profile {
        var c = self; c.kind = kind; return c
    }
}
