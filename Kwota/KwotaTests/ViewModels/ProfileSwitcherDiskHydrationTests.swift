//
//  ProfileSwitcherDiskHydrationTests.swift
//  KwotaTests
//
//  Covers `SwitcherSummaryStore` roundtrip semantics and the
//  `ProfileSwitcherFetchCoordinator` integration that hydrates row
//  cache from disk on init and mirrors evictions back to disk.
//

import XCTest
@testable import Kwota

@MainActor
final class ProfileSwitcherDiskHydrationTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    // MARK: - Store-level

    func test_store_roundtripsClaudeSummary() throws {
        let id = UUID()
        let original = makeSummary(.claude, primary: 0.42, secondary: 0.17,
                                   fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let store = SwitcherSummaryStore(fileURL: temp.file("switcher.json"))
        store.save([id: original])

        let loaded = SwitcherSummaryStore(fileURL: temp.file("switcher.json")).load()
        XCTAssertEqual(loaded.count, 1)
        guard let restored = loaded[id] else {
            return XCTFail("missing entry after roundtrip")
        }
        XCTAssertEqual(restored.providerID, .claude)
        XCTAssertEqual(restored.fetchedAt, original.fetchedAt)
        XCTAssertEqual(restored.primary?.utilization, 0.42)
        XCTAssertEqual(restored.secondary?.utilization, 0.17)
    }

    // MARK: - Coordinator integration

    func test_coordinator_hydratesLastSuccessfulFromDiskOnInit() async {
        // Pre-write a known summary to disk.
        let id = UUID()
        let url = temp.file("switcher.json")
        let preStore = SwitcherSummaryStore(fileURL: url)
        let original = makeSummary(.claude, primary: 0.66, secondary: 0.22,
                                   fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        preStore.save([id: original])

        // A fresh coordinator pointed at the same file must surface the
        // entry as `.loaded` before any fetch runs.
        let store = SwitcherSummaryStore(fileURL: url)
        let c = ProfileSwitcherFetchCoordinator(
            fetcher: MockFetcher(),
            store: store,
            diskWriteDebounce: 0
        )

        guard case let .loaded(s) = c.row(for: id) else {
            return XCTFail("expected .loaded for the pre-seeded id, got \(c.row(for: id))")
        }
        XCTAssertEqual(s.primary?.utilization, 0.66)
        XCTAssertEqual(s.secondary?.utilization, 0.22)
    }

    func test_coordinator_mirrorsStaleIDEvictionToDisk() async {
        // Two profiles cached; one gets archived. Disk must lose the
        // archived entry the next time startFetching runs.
        let a = Profile(id: UUID(), name: "a", authMethod: .cliSync,
                        providerID: .claude, email: "a@x.com")
        let b = Profile(id: UUID(), name: "b", authMethod: .cliSync,
                        providerID: .claude, email: "b@x.com")
        let url = temp.file("switcher.json")
        let store = SwitcherSummaryStore(fileURL: url)
        let fetcher = MockFetcher()
        fetcher.queue([
            a.id: .success(makeSummary(.claude, primary: 0.1, secondary: 0.2)),
            b.id: .success(makeSummary(.claude, primary: 0.3, secondary: 0.4)),
        ])
        let c = ProfileSwitcherFetchCoordinator(
            fetcher: fetcher,
            store: store,
            diskWriteDebounce: 0
        )
        await c.startFetching(profiles: [a, b], skip: nil)
        await c.flushPendingWriteForTests()

        XCTAssertNotNil(store.load()[a.id], "setup: a must be persisted after first fetch")
        XCTAssertNotNil(store.load()[b.id], "setup: b must be persisted after first fetch")

        // Now a is archived. Re-prime b's outcome so startFetching for
        // [b] doesn't run dry on the second pass.
        fetcher.queue([b.id: .success(makeSummary(.claude, primary: 0.5, secondary: 0.6))])
        await c.startFetching(profiles: [b], skip: nil)
        await c.flushPendingWriteForTests()

        let onDisk = store.load()
        XCTAssertNil(onDisk[a.id], "archived profile must be evicted from disk")
        XCTAssertNotNil(onDisk[b.id], "remaining profile must stay on disk")
    }

    func test_coordinator_mirrorsTrustBoundaryEvictionToDisk() async {
        // Profile loads successfully, persists to disk, then a later
        // fetch returns a trust-boundary error (missingCredential). The
        // in-memory cache is evicted by existing coordinator code; the
        // disk entry must follow.
        let p = Profile(id: UUID(), name: "p", authMethod: .cliSync,
                        providerID: .claude, email: "p@x.com")
        let url = temp.file("switcher.json")
        let store = SwitcherSummaryStore(fileURL: url)
        let fetcher = MockFetcher()
        fetcher.queueSequence([
            p.id: [
                .success(makeSummary(.claude, primary: 0.4, secondary: 0.5)),
                .failure(ProfileUsageFetcherError.missingCredential(profileID: p.id)),
            ]
        ])
        // Disable the SWR gate so the post-reset refetch actually runs
        // and the trust-boundary failure can surface — SWR semantics are
        // covered by dedicated tests in ProfileSwitcherFetchCoordinatorTests.
        let c = ProfileSwitcherFetchCoordinator(
            fetcher: fetcher,
            store: store,
            diskWriteDebounce: 0,
            rowFreshnessWindow: 0
        )

        await c.startFetching(profiles: [p], skip: nil)
        await c.flushPendingWriteForTests()
        XCTAssertNotNil(store.load()[p.id], "setup: p must be persisted after first fetch")

        // Force the second outcome to flow: reset clears the in-memory
        // task slot so the next startFetching schedules a new Task.
        c.reset()
        await c.startFetching(profiles: [p], skip: nil)
        await c.flushPendingWriteForTests()

        XCTAssertNil(
            store.load()[p.id],
            "trust-boundary failure must evict the disk entry to match the in-memory eviction"
        )
    }

    func test_coordinator_persistsSeededSummaryAndHydratesOnNextLaunch() async {
        // A profile that was active then the app quit (never fetched as a
        // non-active row) has no persisted entry. Seeding it must now land
        // on disk so a fresh coordinator hydrates it — covering the
        // cold-start gap where the first inactive fetch could otherwise
        // show ⚠️ on a transient failure.
        let p = Profile(id: UUID(), name: "p", authMethod: .cliSync,
                        providerID: .claude, email: "p@x.com")
        let url = temp.file("switcher.json")
        let summary = makeSummary(.claude, primary: 0.77, secondary: 0.33,
                                  fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let c1 = ProfileSwitcherFetchCoordinator(
            fetcher: MockFetcher(),
            store: SwitcherSummaryStore(fileURL: url),
            diskWriteDebounce: 0
        )
        c1.seed([p.id: summary])
        await c1.flushPendingWriteForTests()

        // A second coordinator sharing the same store must hydrate the
        // seeded entry from disk on init.
        let c2 = ProfileSwitcherFetchCoordinator(
            fetcher: MockFetcher(),
            store: SwitcherSummaryStore(fileURL: url),
            diskWriteDebounce: 0
        )
        guard case let .loaded(s) = c2.row(for: p.id) else {
            return XCTFail("expected .loaded for the seeded id, got \(c2.row(for: p.id))")
        }
        XCTAssertEqual(s.providerID, .claude)
        XCTAssertEqual(s.fetchedAt, summary.fetchedAt)
        XCTAssertEqual(s.primary?.utilization, 0.77)
        XCTAssertEqual(s.secondary?.utilization, 0.33)
    }

    func test_coordinator_noopSeedDoesNotOverwriteDisk() async {
        // Seeding an entry that is already present and not newer is a
        // no-op: it must not schedule a redundant write. Observe by
        // pre-writing a fresher entry directly to the store and confirming
        // a no-op seed leaves it untouched.
        let p = Profile(id: UUID(), name: "p", authMethod: .cliSync,
                        providerID: .claude, email: "p@x.com")
        let url = temp.file("switcher.json")
        let fresher = makeSummary(.claude, primary: 0.9, secondary: 0.1,
                                  fetchedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let older = makeSummary(.claude, primary: 0.1, secondary: 0.9,
                                fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))

        // Coordinator hydrates the fresher entry from disk on init.
        SwitcherSummaryStore(fileURL: url).save([p.id: fresher])
        let c = ProfileSwitcherFetchCoordinator(
            fetcher: MockFetcher(),
            store: SwitcherSummaryStore(fileURL: url),
            diskWriteDebounce: 0
        )

        // Seed an older summary — strictly older, so seed skips it and
        // writes nothing.
        c.seed([p.id: older])
        await c.flushPendingWriteForTests()

        let onDisk = SwitcherSummaryStore(fileURL: url).load()
        XCTAssertEqual(onDisk[p.id]?.primary?.utilization, 0.9,
                       "no-op seed must not overwrite the fresher disk entry")
        XCTAssertEqual(onDisk[p.id]?.fetchedAt, fresher.fetchedAt)
    }

    // MARK: - Helpers

    private func makeSummary(_ providerID: ProviderID,
                             primary: Double?,
                             secondary: Double?,
                             fetchedAt: Date = Date()) -> ProviderUsageSummary {
        ProviderUsageSummary(
            providerID: providerID,
            fetchedAt: fetchedAt,
            primary: UsageBucket(utilization: primary, resetsAt: nil),
            secondary: UsageBucket(utilization: secondary, resetsAt: nil),
            payload: EmptyPayload()
        )
    }
}

@MainActor
private final class MockFetcher: ProfileUsageFetching {
    indirect enum Outcome {
        case success(ProviderUsageSummary)
        case failure(Error)
    }

    private var queued: [UUID: [Outcome]] = [:]
    private var calls: [UUID: Int] = [:]

    func queue(_ outcomes: [UUID: Outcome]) {
        queued.merge(outcomes.mapValues { [$0] }) { _, new in new }
    }
    func queueSequence(_ outcomes: [UUID: [Outcome]]) {
        queued.merge(outcomes) { _, new in new }
    }
    func callsFor(_ id: UUID) -> Int { calls[id] ?? 0 }

    func fetch(profile: Profile) async throws -> ProviderUsageSummary {
        calls[profile.id, default: 0] += 1
        guard var outcomes = queued[profile.id], !outcomes.isEmpty else {
            throw NSError(domain: "MockFetcher", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "no outcome queued for \(profile.id)"
            ])
        }
        let outcome = outcomes.removeFirst()
        queued[profile.id] = outcomes
        switch outcome {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }
}
