//
//  SwitcherSummaryStoreTests.swift
//  KwotaTests
//
//  Covers the chrome-only persistence envelope, plus the Antigravity
//  exception: overagesEnabled survives round-trip so a cold-start switcher
//  row renders the dim grey AI Credits bar (and the "Overages off"
//  tooltip suffix) even before the first fresh fetch arrives.
//

import XCTest
@testable import Kwota

@MainActor
final class SwitcherSummaryStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("switcher-summaries-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL)
        try await super.tearDown()
    }

    private func makeSummary(
        providerID: ProviderID = .claude,
        payload: any Sendable = UsageSnapshot.zeroes()
    ) -> ProviderUsageSummary {
        ProviderUsageSummary(
            providerID: providerID,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: UsageBucket(utilization: 25, resetsAt: nil),
            secondary: UsageBucket(utilization: 50, resetsAt: nil),
            payload: payload,
            retryAfter: nil
        )
    }

    private func loadedAntigravitySnapshot(
        from map: [UUID: ProviderUsageSummary],
        id: UUID
    ) -> AntigravityUsageSnapshot? {
        (map[id]?.payload as? AntigravityUsagePayload)?.snapshot
    }

    // MARK: - Claude / Codex (no payload metadata)

    func test_roundTrip_dropsPayload_forNonAntigravityProviders() {
        let store = SwitcherSummaryStore(fileURL: fileURL)
        let id = UUID()
        store.save([id: makeSummary(providerID: .claude)])

        let loaded = store.load()
        guard let s = loaded[id] else { return XCTFail("missing entry") }
        XCTAssertEqual(s.providerID, .claude)
        XCTAssertEqual(s.primary?.utilization, 25)
        XCTAssertEqual(s.secondary?.utilization, 50)
        // Payload is intentionally substituted with EmptyPayload for
        // providers whose switcher chrome doesn't depend on it.
        XCTAssertNotNil(s.payload as? EmptyPayload)
    }

    // MARK: - Antigravity overage state

    func test_roundTrip_preservesOveragesEnabled_forAntigravity() {
        // Overages OFF in the saved snapshot must survive into the loaded
        // payload — otherwise AntigravityProvider's switcherBarDimming
        // returns false on cold start and the AIC bar paints healthy
        // green for the 1-3s window before a fresh fetch lands.
        let store = SwitcherSummaryStore(fileURL: fileURL)
        let id = UUID()
        var snap = AntigravityUsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        snap.overagesEnabled = false
        store.save([id: makeSummary(providerID: .antigravity, payload: snap)])

        let loaded = store.load()
        let payload = loadedAntigravitySnapshot(from: loaded, id: id)
        XCTAssertNotNil(payload, "Antigravity row must rehydrate with a real snapshot, not EmptyPayload")
        XCTAssertEqual(payload?.overagesEnabled, false)
    }

    func test_roundTrip_preservesOveragesEnabled_whenTrue() {
        let store = SwitcherSummaryStore(fileURL: fileURL)
        let id = UUID()
        var snap = AntigravityUsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        snap.overagesEnabled = true
        store.save([id: makeSummary(providerID: .antigravity, payload: snap)])

        let payload = loadedAntigravitySnapshot(from: store.load(), id: id)
        XCTAssertEqual(payload?.overagesEnabled, true)
    }

    func test_roundTrip_overagesEnabledNil_remainsNilOnRehydrate() {
        // SQLite read failed at save-time → overagesEnabled is nil.
        // The rehydrated snapshot must keep it nil (treated as
        // "unknown" downstream), not flip to true / false.
        let store = SwitcherSummaryStore(fileURL: fileURL)
        let id = UUID()
        let snap = AntigravityUsageSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertNil(snap.overagesEnabled)
        store.save([id: makeSummary(providerID: .antigravity, payload: snap)])

        let payload = loadedAntigravitySnapshot(from: store.load(), id: id)
        XCTAssertNotNil(payload, "Antigravity row rehydrates with a snapshot even when overagesEnabled is nil")
        XCTAssertNil(payload?.overagesEnabled)
    }

    // MARK: - Backwards compat

    func test_load_acceptsOldFile_withoutAntigravityOveragesField() throws {
        // Old-format save: write a real summary with overagesEnabled = nil
        // (the value a previous build would have produced before the new
        // field existed) and then strip the new key from the on-disk
        // JSON. Loading must still succeed and rehydrate the Antigravity
        // payload with overagesEnabled = nil.
        let store = SwitcherSummaryStore(fileURL: fileURL)
        let id = UUID()
        store.save([id: makeSummary(
            providerID: .antigravity,
            payload: AntigravityUsageSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        )])

        // Strip the new field from the on-disk JSON to simulate an
        // older app version that doesn't know about it.
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        let stripped = raw
            .replacingOccurrences(of: "\"antigravityOveragesEnabled\":null,", with: "")
            .replacingOccurrences(of: ",\"antigravityOveragesEnabled\":null", with: "")
            .replacingOccurrences(of: "\"antigravityOveragesEnabled\":null", with: "")
        try stripped.data(using: .utf8)!.write(to: fileURL)
        XCTAssertFalse(stripped.contains("antigravityOveragesEnabled"),
                       "fixture must not still carry the new field")

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1, "old file must decode without the new field present")
        let payload = loadedAntigravitySnapshot(from: loaded, id: id)
        XCTAssertNotNil(payload)
        XCTAssertNil(payload?.overagesEnabled,
                     "missing field decodes as nil (= unknown)")
    }
}
