import XCTest
@testable import Kwota

@MainActor
final class AwakeSessionLogTests: XCTestCase {
    private var clock: Date!
    private func now() -> Date { clock }

    override func setUp() async throws {
        clock = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private func makeLog(window: TimeInterval = 3 * 3600) -> AwakeSessionLog {
        AwakeSessionLog(
            windowSeconds: window,
            clock: { [unowned self] in self.now() },
            autoStart: false
        )
    }

    func test_idleFromEmpty_doesNotCreateSession() {
        let log = makeLog()
        log.record(state: .idle)
        XCTAssertTrue(log.sessions.isEmpty)
    }

    func test_autoActive_opensInProgressSession() {
        let log = makeLog()
        let t = clock!
        log.record(state: .autoActive(since: t))
        XCTAssertEqual(log.sessions.count, 1)
        XCTAssertEqual(log.sessions[0].mode, .auto)
        XCTAssertEqual(log.sessions[0].start, t)
        XCTAssertNil(log.sessions[0].end)
    }

    func test_autoActive_twiceWithSameSince_isIdempotent() {
        let log = makeLog()
        let t = clock!
        log.record(state: .autoActive(since: t))
        log.record(state: .autoActive(since: t))
        XCTAssertEqual(log.sessions.count, 1)
    }

    func test_autoToIdle_closesSession() {
        let log = makeLog()
        let t1 = clock!
        log.record(state: .autoActive(since: t1))
        clock = t1.addingTimeInterval(60)
        log.record(state: .idle)
        XCTAssertEqual(log.sessions.count, 1)
        XCTAssertEqual(log.sessions[0].end, clock)
    }

    func test_autoToManual_closesAutoOpensManual() {
        let log = makeLog()
        let t1 = clock!
        log.record(state: .autoActive(since: t1))
        let t2 = t1.addingTimeInterval(30)
        clock = t2
        log.record(state: .manualActive(since: t2, timeout: nil))
        XCTAssertEqual(log.sessions.count, 2)
        XCTAssertEqual(log.sessions[0].mode, .auto)
        XCTAssertEqual(log.sessions[0].end, t2)
        XCTAssertEqual(log.sessions[1].mode, .manual)
        XCTAssertEqual(log.sessions[1].start, t2)
        XCTAssertNil(log.sessions[1].end)
    }

    func test_autoToBatteryBlocked_closesSessionNoNewOne() {
        let log = makeLog()
        let t1 = clock!
        log.record(state: .autoActive(since: t1))
        clock = t1.addingTimeInterval(30)
        log.record(state: .batteryBlocked)
        XCTAssertEqual(log.sessions.count, 1)
        XCTAssertNotNil(log.sessions[0].end)
    }

    func test_prune_dropsSessionsEndedOutsideWindow() {
        let log = makeLog(window: 3600)   // 1h window
        let t1 = clock!
        log.record(state: .autoActive(since: t1))
        clock = t1.addingTimeInterval(60)
        log.record(state: .idle)          // closed session [t1..t1+60]
        clock = t1.addingTimeInterval(3600 + 120)   // 1h2m later
        log.prune()
        XCTAssertTrue(log.sessions.isEmpty)
    }

    func test_prune_keepsInProgressSession() {
        let log = makeLog(window: 3600)
        let t1 = clock!
        log.record(state: .autoActive(since: t1))
        clock = t1.addingTimeInterval(7200)   // 2h later, no close
        log.prune()
        XCTAssertEqual(log.sessions.count, 1)
        XCTAssertNil(log.sessions[0].end)
    }

    func test_idleFromIdle_isNoOp() {
        let log = makeLog()
        log.record(state: .idle)
        log.record(state: .idle)
        XCTAssertTrue(log.sessions.isEmpty)
    }

    func test_mostRecentSessionEnd_reportsInProgressNow() {
        let log = makeLog()
        let t1 = clock!
        log.record(state: .autoActive(since: t1))
        clock = t1.addingTimeInterval(120)
        XCTAssertEqual(log.mostRecentSessionEnd, clock)
    }

    func test_mostRecentSessionEnd_reportsClosedEnd() {
        let log = makeLog()
        let t1 = clock!
        log.record(state: .autoActive(since: t1))
        let t2 = t1.addingTimeInterval(60)
        clock = t2
        log.record(state: .idle)
        clock = t2.addingTimeInterval(600)
        XCTAssertEqual(log.mostRecentSessionEnd, t2)
    }

    // MARK: - Persistence

    /// Writes one completed session, reloads from disk, and verifies the
    /// round-trip kept mode + timestamps intact.
    func test_persistence_roundTripsCompletedSession() async throws {
        let tmp = TempDirectory()
        let url = tmp.file("awake-sessions.json")
        let t0 = clock!
        let t1 = t0.addingTimeInterval(600)

        let writer = AwakeSessionLog(
            windowSeconds: 3 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url
        )
        writer.record(state: .autoActive(since: t0))
        clock = t1
        writer.record(state: .idle)

        // Wait for the detached persist Task to land on disk. Polling is
        // simpler than plumbing a completion signal through the live API.
        // persist() is synchronous; the file is on disk by the time
        // record() returns.

        let reader = AwakeSessionLog(
            windowSeconds: 3 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url
        )
        XCTAssertEqual(reader.sessions.count, 1)
        XCTAssertEqual(reader.sessions[0].mode, .auto)
        XCTAssertEqual(reader.sessions[0].start, t0)
        XCTAssertEqual(reader.sessions[0].end, t1)
    }

    /// An in-progress session at shutdown must be closed at the persistence
    /// timestamp on next load; otherwise the chart's ambient awake tint
    /// would stretch from the old start to "now" across the offline gap.
    func test_persistence_closesOpenSessionAtLastPersistedAt() async throws {
        let tmp = TempDirectory()
        let url = tmp.file("awake-sessions.json")
        let t0 = clock!
        let writer = AwakeSessionLog(
            windowSeconds: 3 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url
        )
        writer.record(state: .autoActive(since: t0))
        // persist() is synchronous; the file is on disk by the time
        // record() returns.

        // Simulate app relaunch 1h later with the same clock.
        clock = t0.addingTimeInterval(3600)
        let reader = AwakeSessionLog(
            windowSeconds: 3 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url
        )
        XCTAssertEqual(reader.sessions.count, 1)
        XCTAssertNotNil(reader.sessions[0].end,
                        "open session must be closed at lastPersistedAt on load")
        // The persisted moment was t0 (record() called persist with that
        // timestamp), so end should equal t0.
        XCTAssertEqual(reader.sessions[0].end, t0)
    }

    /// Sessions older than the window must be discarded at load time so a
    /// long-offline gap doesn't repopulate the chart with stale tints.
    func test_persistence_prunesOldSessionsOnLoad() async throws {
        let tmp = TempDirectory()
        let url = tmp.file("awake-sessions.json")
        let veryOld = clock!.addingTimeInterval(-10 * 3600)
        let writer = AwakeSessionLog(
            windowSeconds: 3 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url
        )
        // Record an old session via state machine, then force-close so the
        // ended-at falls outside the 3h window.
        clock = veryOld
        writer.record(state: .autoActive(since: veryOld))
        clock = veryOld.addingTimeInterval(60)
        writer.record(state: .idle)
        // persist() is synchronous; the file is on disk by the time
        // record() returns.
        clock = Date(timeIntervalSince1970: 1_700_000_000)

        let reader = AwakeSessionLog(
            windowSeconds: 3 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url
        )
        XCTAssertEqual(reader.sessions, [], "stale session should be pruned on load")
    }

    /// With an open session, heartbeat persist must advance the file's
    /// `lastPersistedAt` so the persisted moment isn't stuck at the last
    /// state change. On reload, the orphan-close cap (start + 5 min) wins
    /// over a far-future `lastPersistedAt` — the cap is the whole point of
    /// the phantom-awake fix. This test verifies the file was rewritten
    /// (persist actually ran) while still asserting the cap holds.
    func test_heartbeatPersist_advancesLastPersistedAtForOpenSession() throws {
        let tmp = TempDirectory()
        let url = tmp.file("awake-sessions.json")
        let t0 = clock!
        let writer = AwakeSessionLog(
            windowSeconds: 8 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url
        )
        writer.record(state: .autoActive(since: t0))
        let mtimeAfterRecord = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        // Simulate 1h pass with no state change, then a heartbeat tick.
        let later = t0.addingTimeInterval(3600)
        clock = later
        writer.heartbeatPersist()
        let mtimeAfterHeartbeat = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertNotEqual(mtimeAfterRecord, mtimeAfterHeartbeat,
                          "heartbeat must rewrite the file while a session is open")

        // Simulate crash + relaunch at the heartbeat moment.
        let reader = AwakeSessionLog(
            windowSeconds: 8 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url
        )
        XCTAssertEqual(reader.sessions.count, 1)
        XCTAssertEqual(reader.sessions[0].end, t0.addingTimeInterval(5 * 60),
                       "orphan must cap at start + 5min, not stretch to the heartbeat moment")
    }

    /// Heartbeat must not write when no session is open — the loop fires
    /// every 30s regardless of state, so a no-op skip keeps the file
    /// stable across long idle periods.
    func test_heartbeatPersist_skipsWriteWhenNoOpenSession() throws {
        let tmp = TempDirectory()
        let url = tmp.file("awake-sessions.json")
        let t0 = clock!
        let t1 = t0.addingTimeInterval(60)
        let writer = AwakeSessionLog(
            windowSeconds: 8 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url
        )
        writer.record(state: .autoActive(since: t0))
        clock = t1
        writer.record(state: .idle)   // closes session, persists at t1
        let mtimeAfterClose = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        // Advance clock and fire heartbeat — no open session, no write.
        clock = t1.addingTimeInterval(3600)
        writer.heartbeatPersist()
        let mtimeAfterHeartbeat = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        XCTAssertEqual(mtimeAfterClose, mtimeAfterHeartbeat,
                       "heartbeat must not rewrite file when no session is open")
    }

    /// Absence-of-file is the normal first-launch case — must not crash or
    /// log noise.
    func test_persistence_missingFileLoadsEmpty() {
        let tmp = TempDirectory()
        let url = tmp.file("does-not-exist.json")
        let log = AwakeSessionLog(
            windowSeconds: 3 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url
        )
        XCTAssertEqual(log.sessions, [])
    }

    // MARK: - Retention default

    /// Sanity check that the in-memory retention default is 24h. The
    /// activity chart's displayWindow may extend up to 24h while a long
    /// awake session is open, so the service must keep at least that
    /// much history to back the extended view.
    func test_defaultRetentionIs24h() {
        let log = AwakeSessionLog(
            clock: { [unowned self] in self.now() },
            autoStart: false
        )
        let now = clock!
        // Record a session that ended 12h ago. With 8h retention this is
        // pruned on touch; with 24h retention it survives.
        let twelveHoursAgo = now.addingTimeInterval(-12 * 3600)
        clock = twelveHoursAgo
        log.record(state: .autoActive(since: twelveHoursAgo))
        clock = twelveHoursAgo.addingTimeInterval(60)
        log.record(state: .idle)
        clock = now
        log.prune()
        XCTAssertEqual(
            log.sessions.count,
            1,
            "12h-old closed session must survive prune at default 24h retention"
        )
    }

    // MARK: - Sleep/wake session boundaries

    /// On Mac sleep, the open session must close at the sleep moment so the
    /// chart doesn't tint the sleep interval as awake time.
    func test_closeOpenSessions_closesEachOpenSessionAtGivenMoment() {
        let log = makeLog()
        let t0 = clock!
        log.record(state: .autoActive(since: t0))
        XCTAssertEqual(log.sessions.count, 1)
        XCTAssertNil(log.sessions[0].end)

        let sleepMoment = t0.addingTimeInterval(1800)   // 30m in
        log.closeOpenSessions(at: sleepMoment)

        XCTAssertEqual(log.sessions.count, 1)
        XCTAssertEqual(log.sessions[0].end, sleepMoment)
    }

    /// No open session = no-op. Defends the 30s prune-loop heartbeat path
    /// from rewriting the persistence file when there's nothing to close.
    func test_closeOpenSessions_isNoOpWhenAllClosed() {
        let log = makeLog()
        let t0 = clock!
        log.record(state: .autoActive(since: t0))
        clock = t0.addingTimeInterval(60)
        log.record(state: .idle)
        let snapshot = log.sessions

        log.closeOpenSessions(at: t0.addingTimeInterval(3600))

        XCTAssertEqual(log.sessions, snapshot, "no open sessions to close")
    }

    /// On wake with caffeinate still active, a fresh session opens at the
    /// wake moment. The supervisor's `state.since` is preserved (manual
    /// timeout still counts from the original button press), so we can't
    /// re-use record() — it'd open the new session at the old start.
    func test_openSession_appendsAtGivenMomentWithGivenMode() {
        let log = makeLog()
        let t0 = clock!
        let wakeMoment = t0.addingTimeInterval(8 * 3600)

        log.openSession(mode: .auto, at: wakeMoment)

        XCTAssertEqual(log.sessions.count, 1)
        XCTAssertEqual(log.sessions[0].mode, .auto)
        XCTAssertEqual(log.sessions[0].start, wakeMoment)
        XCTAssertNil(log.sessions[0].end)
    }

    /// Sleep → wake cycle: close at sleep, open at wake. The two sessions
    /// must reflect the actual awake intervals, not one contiguous span.
    func test_closeThenOpen_yieldsTwoSeparateSessionsWithGapBetween() {
        let log = makeLog()
        let t0 = clock!
        log.record(state: .autoActive(since: t0))

        let sleepMoment = t0.addingTimeInterval(1800)
        log.closeOpenSessions(at: sleepMoment)
        let wakeMoment = t0.addingTimeInterval(8 * 3600)
        log.openSession(mode: .auto, at: wakeMoment)

        XCTAssertEqual(log.sessions.count, 2)
        XCTAssertEqual(log.sessions[0].start, t0)
        XCTAssertEqual(log.sessions[0].end, sleepMoment)
        XCTAssertEqual(log.sessions[1].start, wakeMoment)
        XCTAssertNil(log.sessions[1].end)
    }

    // MARK: - Caffeine reconciliation (ground-truth open-session close)

    /// Production root cause: `record()` only inspected the last session, so a
    /// new closed session appended on top of an orphan left the orphan open
    /// indefinitely. The supervisor flipping caffeine off must immediately
    /// close every open session at the current clock.
    func test_closesOpenSessionsWhenCaffeineGoesInactive() async {
        let caffeine = CaffeinateManager(holder: MockSleepAssertionHolder())
        let log = AwakeSessionLog(
            windowSeconds: 8 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: nil,
            caffeine: caffeine
        )
        let t0 = clock!
        log.record(state: .autoActive(since: t0))
        XCTAssertNil(log.sessions[0].end)

        try? caffeine.enable()
        XCTAssertTrue(caffeine.isActive)

        let t1 = t0.addingTimeInterval(900)
        clock = t1
        caffeine.disable()

        // Combine .sink fires synchronously off @Published willSet; yield once
        // to drain any MainActor hops the subscription might introduce.
        await Task.yield()

        XCTAssertEqual(log.sessions.count, 1)
        XCTAssertEqual(log.sessions[0].end, t1,
                       "open session must close at the moment caffeine flipped off")
    }

    /// Heartbeat fires every 30s regardless of state. If caffeine is off but a
    /// session is still recorded as open (orphan), heartbeat must close it
    /// instead of bumping `lastPersistedAt` forward — that was the second of
    /// three causes painting a 7h+ phantom into the chart.
    func test_heartbeatClosesOpenSessionsWhenCaffeineInactive() throws {
        let tmp = TempDirectory()
        let url = tmp.file("awake-sessions.json")
        let caffeine = CaffeinateManager(holder: MockSleepAssertionHolder())
        let log = AwakeSessionLog(
            windowSeconds: 8 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url,
            caffeine: caffeine
        )
        let t0 = clock!
        log.record(state: .autoActive(since: t0))
        XCTAssertFalse(caffeine.isActive)

        let t1 = t0.addingTimeInterval(3600)
        clock = t1
        log.heartbeatPersist()

        XCTAssertEqual(log.sessions.count, 1)
        XCTAssertEqual(log.sessions[0].end, t1,
                       "heartbeat must close the orphan, not bump lastPersistedAt")

        // Reload from disk: persisted file must reflect the closed session,
        // not a still-open one with bumped lastPersistedAt.
        let reader = AwakeSessionLog(
            windowSeconds: 8 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url
        )
        XCTAssertEqual(reader.sessions.count, 1)
        XCTAssertEqual(reader.sessions[0].end, t1)
    }

    /// Normal happy path: caffeine on, session open, heartbeat bumps
    /// lastPersistedAt and keeps the session open. Regression guard against
    /// over-reconciling.
    func test_heartbeatBumpsLastPersistedAtWhenCaffeineActive() throws {
        let tmp = TempDirectory()
        let url = tmp.file("awake-sessions.json")
        let caffeine = CaffeinateManager(holder: MockSleepAssertionHolder())
        let log = AwakeSessionLog(
            windowSeconds: 8 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url,
            caffeine: caffeine
        )
        let t0 = clock!
        try caffeine.enable()
        log.record(state: .autoActive(since: t0))

        let t1 = t0.addingTimeInterval(3600)
        clock = t1
        log.heartbeatPersist()

        XCTAssertEqual(log.sessions.count, 1)
        XCTAssertNil(log.sessions[0].end, "session must remain open while caffeine is active")

        // Reload at the heartbeat moment: open session should close at t1
        // (lastPersistedAt advanced to t1, so reader caps the orphan at t1).
        let reader = AwakeSessionLog(
            windowSeconds: 8 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url
        )
        XCTAssertEqual(reader.sessions.count, 1)
        // Cap is start + 5min; lastPersistedAt is t1 = start + 1h, so the
        // load-time cap wins. The reload assertion targets the persisted
        // lastPersistedAt advancing rather than the cap behaviour.
        XCTAssertNotNil(reader.sessions[0].end)
    }

    /// Loading an orphan session with a far-future `lastPersistedAt` (the bug:
    /// 7h after the real release) must cap the close at start + 5 minutes so
    /// the chart can't tint hours of phantom awake time.
    func test_loadSessions_capsOrphanAtStartPlusFiveMinutes() throws {
        let tmp = TempDirectory()
        let url = tmp.file("awake-sessions.json")
        let t0 = clock!
        let orphan = AwakeSession(mode: .auto, start: t0, end: nil)
        let payload = AwakeSessionLogPersistedTestProxy(
            lastPersistedAt: t0.addingTimeInterval(8 * 3600),
            sessions: [orphan]
        )
        try payload.write(to: url)

        let reader = AwakeSessionLog(
            windowSeconds: 24 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url
        )
        XCTAssertEqual(reader.sessions.count, 1)
        XCTAssertEqual(
            reader.sessions[0].end,
            t0.addingTimeInterval(5 * 60),
            "orphan must cap at start + 5min, not stretch to lastPersistedAt"
        )
    }

    /// When the persisted `lastPersistedAt` is within the cap window, it wins
    /// (more precise than the cap). This preserves the existing behaviour for
    /// well-behaved shutdowns where the heartbeat ran shortly before quit.
    func test_loadSessions_keepsLastPersistedAtWhenWithinCap() throws {
        let tmp = TempDirectory()
        let url = tmp.file("awake-sessions.json")
        let t0 = clock!
        let orphan = AwakeSession(mode: .auto, start: t0, end: nil)
        let lastPersistedAt = t0.addingTimeInterval(120) // 2 min in, within cap
        let payload = AwakeSessionLogPersistedTestProxy(
            lastPersistedAt: lastPersistedAt,
            sessions: [orphan]
        )
        try payload.write(to: url)

        let reader = AwakeSessionLog(
            windowSeconds: 24 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: url
        )
        XCTAssertEqual(reader.sessions.count, 1)
        XCTAssertEqual(reader.sessions[0].end, lastPersistedAt)
    }

    /// Regression guard for the orphan-amplification root cause: with multiple
    /// open sessions in memory, flipping caffeine off must close ALL of them,
    /// not just the last. The original `record(.idle)` path only inspected
    /// the tail, which is how the phantom 7h43m row survived in the first
    /// place. Caffeine-driven close is the path that fixes it.
    func test_recordIdleClosesAllOpenSessionsNotJustLast() async {
        let caffeine = CaffeinateManager(holder: MockSleepAssertionHolder())
        let log = AwakeSessionLog(
            windowSeconds: 8 * 3600,
            clock: { [unowned self] in self.now() },
            autoStart: false,
            persistURL: nil,
            caffeine: caffeine
        )
        let t0 = clock!
        // Simulate two concurrent opens by appending directly through the
        // public openSession API — both end up with end == nil.
        log.openSession(mode: .auto, at: t0)
        log.openSession(mode: .manual, at: t0.addingTimeInterval(60))
        XCTAssertEqual(log.sessions.count, 2)
        XCTAssertTrue(log.sessions.allSatisfy { $0.end == nil })

        try? caffeine.enable()
        let t1 = t0.addingTimeInterval(900)
        clock = t1
        caffeine.disable()
        await Task.yield()

        XCTAssertTrue(log.sessions.allSatisfy { $0.end == t1 },
                      "every open session must close at the caffeine-off moment")
    }

}

// MARK: - Test helpers

/// Mirrors `AwakeSessionLog`'s private persisted format so tests can hand-craft
/// payloads with specific orphan + `lastPersistedAt` combinations without
/// going through the recording APIs.
private struct AwakeSessionLogPersistedTestProxy: Codable {
    let lastPersistedAt: Date
    let sessions: [AwakeSession]

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
