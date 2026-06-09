//
//  ActivityHistorianTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

@MainActor
final class ActivityHistorianTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeHistorian() -> ActivityHistorian {
        // autoBackfill off so the test never reads the real ~/.claude tree.
        ActivityHistorian(windowSeconds: 24 * 3600, clock: { self.now }, autoBackfill: false)
    }

    func test_recordProvider_appendsAndIsolatesByProvider() {
        let h = makeHistorian()
        h.record(provider: .codex, at: now.addingTimeInterval(-100))
        h.record(provider: .antigravity, at: now.addingTimeInterval(-200))

        XCTAssertEqual(h.timestamps(for: .codex).count, 1)
        XCTAssertEqual(h.timestamps(for: .antigravity).count, 1)
        XCTAssertTrue(h.timestamps(for: .claude).isEmpty)         // Claude store untouched
        XCTAssertTrue(h.timestamps.isEmpty)                       // legacy alias == Claude
    }

    func test_recordProvider_ignoresClaude() {
        let h = makeHistorian()
        h.record(provider: .claude, at: now)
        // Claude must flow through record(_ events:), not this path.
        XCTAssertTrue(h.timestamps(for: .claude).isEmpty)
    }

    func test_recordProvider_dropsOutOfWindow() {
        let h = makeHistorian()
        h.record(provider: .codex, at: now.addingTimeInterval(-48 * 3600))  // older than 24h
        XCTAssertTrue(h.timestamps(for: .codex).isEmpty)
    }

    func test_recordProvider_keepsSorted() {
        let h = makeHistorian()
        h.record(provider: .codex, at: now.addingTimeInterval(-100))
        h.record(provider: .codex, at: now.addingTimeInterval(-300))
        h.record(provider: .codex, at: now.addingTimeInterval(-200))
        XCTAssertEqual(h.timestamps(for: .codex), h.timestamps(for: .codex).sorted())
    }

    func test_nonClaudeEvent_dedupedAcrossLiveAndBackfill() {
        // The live first-sight read and the one-shot launch backfill can both
        // process a session created just after start(); the same reply date must
        // count once, not twice (non-Claude has no uuid to dedup on).
        let h = makeHistorian()
        let d = now.addingTimeInterval(-100)
        h.record(provider: .codex, at: d)                              // live path
        h.applyProviderBackfill([(provider: .codex, dates: [d])])      // backfill of the same file
        XCTAssertEqual(h.timestamps(for: .codex), [d])
    }

    func test_nonClaudeBackfill_dedupesWithinAndAgainstLive() {
        // Backfill order vs live order shouldn't matter, and a date repeated
        // within one backfill batch must also collapse.
        let h = makeHistorian()
        let d1 = now.addingTimeInterval(-100)
        let d2 = now.addingTimeInterval(-50)
        h.applyProviderBackfill([(provider: .codex, dates: [d1, d1, d2])])  // d1 twice in batch
        h.record(provider: .codex, at: d2)                                  // live re-emits d2
        XCTAssertEqual(h.timestamps(for: .codex), [d1, d2])
    }

    func test_activeProviders_returnsInWindowInStableOrder() {
        let h = makeHistorian()
        h.record(provider: .antigravity, at: now.addingTimeInterval(-100))
        h.record(provider: .codex, at: now.addingTimeInterval(-100))
        let range = now.addingTimeInterval(-3600)...now
        // Stable order: claude, codex, antigravity (claude absent here).
        XCTAssertEqual(h.activeProviders(in: range), [.codex, .antigravity])
    }

    func test_activeProviders_excludesOutOfWindow() {
        let h = makeHistorian()
        h.record(provider: .codex, at: now.addingTimeInterval(-10 * 3600))
        let range = now.addingTimeInterval(-3600)...now   // only last hour
        XCTAssertEqual(h.activeProviders(in: range), [])
    }

    func test_backfillProviders_seedsFromScanner() {
        let h = makeHistorian()
        let t1 = now.addingTimeInterval(-500)
        let t2 = now.addingTimeInterval(-600)
        let scanner = ProviderActivityScanner(
            provider: .codex, roots: [],
            matchesFile: { _ in false },
            timestamp: { _ in nil }
        )
        // roots empty → no-op, no crash.
        h.backfillProviders([scanner])
        XCTAssertTrue(h.timestamps(for: .codex).isEmpty)

        // Verify the store appends + counts via the live path.
        h.record(provider: .codex, at: t1)
        h.record(provider: .codex, at: t2)
        XCTAssertEqual(h.timestamps(for: .codex).count, 2)
    }

    func test_claudePathUnchanged() {
        let h = makeHistorian()
        let ev = makeAssistantEvent(uuid: "u1", at: now.addingTimeInterval(-100))
        h.record([ev])
        XCTAssertEqual(h.timestamps.count, 1)
        XCTAssertEqual(h.timestamps(for: .claude).count, 1)
    }

    func test_applyClaudeBackfill_dedupesByUUIDAndSorts() {
        let h = makeHistorian()
        let t0 = now.addingTimeInterval(-300)
        let t1 = now.addingTimeInterval(-100)
        h.applyClaudeBackfill([
            ActivityHistorian.ScannedEvent(uuid: "a", date: t1),
            ActivityHistorian.ScannedEvent(uuid: "a", date: t1),  // dup uuid → ignored
            ActivityHistorian.ScannedEvent(uuid: "b", date: t0),
        ])
        XCTAssertEqual(h.timestamps, [t0, t1])   // deduped + sorted
    }

    func test_applyClaudeBackfill_dedupesAgainstRecordedEvents() {
        let h = makeHistorian()
        let ev = makeAssistantEvent(uuid: "x", at: now.addingTimeInterval(-100))
        h.record([ev])                                   // arrives before backfill applies
        h.applyClaudeBackfill([ActivityHistorian.ScannedEvent(uuid: "x", date: now.addingTimeInterval(-100))])
        XCTAssertEqual(h.timestamps.count, 1)            // not double-counted
    }

    func test_scanClaudeBackfill_parsesAssistantInWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-scan-\(UUID().uuidString)", isDirectory: true)
        let proj = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let inWin = now.addingTimeInterval(-3600)
        let outWin = now.addingTimeInterval(-48 * 3600)
        let lines = [
            "{\"type\":\"assistant\",\"uuid\":\"a\",\"timestamp\":\"\(iso.string(from: inWin))\"}",
            "{\"type\":\"user\",\"uuid\":\"u\",\"timestamp\":\"\(iso.string(from: inWin))\"}",       // not assistant
            "{\"type\":\"assistant\",\"uuid\":\"b\",\"timestamp\":\"\(iso.string(from: outWin))\"}", // out of window
        ].joined(separator: "\n")
        try lines.write(to: proj.appendingPathComponent("x.jsonl"), atomically: true, encoding: .utf8)

        let cutoff = now.addingTimeInterval(-24 * 3600)
        let events = ActivityHistorian.scanClaudeBackfill(root: root, cutoff: cutoff)
        XCTAssertEqual(events.map(\.uuid), ["a"])   // only the in-window assistant line
    }

    func test_backfillProvidersAsync_emptyRootsNoCrash() async {
        let h = makeHistorian()
        let scanner = ProviderActivityScanner(
            provider: .codex, roots: [],
            matchesFile: { _ in false }, timestamp: { _ in nil })
        await h.backfillProvidersAsync([scanner])
        XCTAssertTrue(h.timestamps(for: .codex).isEmpty)
    }

    // MARK: - Disk persistence

    /// `/codex` via app-server emits provider events at runtime with no source
    /// file to backfill from. Persisting non-Claude events lets the chart
    /// survive Kwota relaunch instead of going blank.
    func test_persistedProviderEvents_restoredOnNextInit() {
        let tmp = TempDirectory()
        let url = tmp.file("activity-events.json")

        // First session: record events, persist to disk on every record.
        let h1 = ActivityHistorian(
            windowSeconds: 24 * 3600, clock: { self.now }, autoBackfill: false,
            persistURL: url)
        h1.record(provider: .codex, at: now.addingTimeInterval(-100))
        h1.record(provider: .codex, at: now.addingTimeInterval(-200))
        h1.record(provider: .antigravity, at: now.addingTimeInterval(-300))

        // Second session: same persist URL — should load from disk.
        let h2 = ActivityHistorian(
            windowSeconds: 24 * 3600, clock: { self.now }, autoBackfill: false,
            persistURL: url)
        XCTAssertEqual(h2.timestamps(for: .codex).count, 2)
        XCTAssertEqual(h2.timestamps(for: .antigravity).count, 1)
        XCTAssertTrue(h2.timestamps(for: .claude).isEmpty)
    }

    /// On restore, dates older than the window are discarded — a long-quit
    /// Kwota shouldn't repopulate the chart with stale events.
    func test_persistLoad_dropsOutOfWindowDates() {
        let tmp = TempDirectory()
        let url = tmp.file("activity-events.json")

        let h1 = ActivityHistorian(
            windowSeconds: 24 * 3600, clock: { self.now }, autoBackfill: false,
            persistURL: url)
        h1.record(provider: .codex, at: now.addingTimeInterval(-1 * 3600))   // in window
        h1.record(provider: .codex, at: now.addingTimeInterval(-23 * 3600))  // in window

        // Move the clock forward 25h — the events on disk are now all > 24h
        // old relative to the loader's `now`.
        let later = now.addingTimeInterval(25 * 3600)
        let h2 = ActivityHistorian(
            windowSeconds: 24 * 3600, clock: { later }, autoBackfill: false,
            persistURL: url)
        XCTAssertTrue(h2.timestamps(for: .codex).isEmpty)
    }

    /// Restored events are also installed into `seenOtherDates` so the next
    /// backfill scan doesn't double-count the same date.
    func test_persistLoad_dedupsAgainstRestoredEvents() {
        let tmp = TempDirectory()
        let url = tmp.file("activity-events.json")
        let date = now.addingTimeInterval(-100)

        let h1 = ActivityHistorian(
            windowSeconds: 24 * 3600, clock: { self.now }, autoBackfill: false,
            persistURL: url)
        h1.record(provider: .codex, at: date)

        let h2 = ActivityHistorian(
            windowSeconds: 24 * 3600, clock: { self.now }, autoBackfill: false,
            persistURL: url)
        // Re-record the same date — should be dropped by dedup.
        h2.record(provider: .codex, at: date)
        XCTAssertEqual(h2.timestamps(for: .codex).count, 1)
    }

    /// Missing persist file (first launch) loads as empty — must not crash or
    /// pollute the store with anything.
    func test_persistLoad_missingFileLoadsEmpty() {
        let tmp = TempDirectory()
        let url = tmp.file("nonexistent.json")
        let h = ActivityHistorian(
            windowSeconds: 24 * 3600, clock: { self.now }, autoBackfill: false,
            persistURL: url)
        XCTAssertTrue(h.timestamps(for: .codex).isEmpty)
        XCTAssertTrue(h.timestamps(for: .antigravity).isEmpty)
    }

    // MARK: - Helpers

    private func makeAssistantEvent(uuid: String, at date: Date) -> UsageEvent {
        UsageEvent(
            uuid: uuid,
            sessionId: "test-session",
            timestamp: date,
            tokens: TokenBreakdown()
        )
    }
}
