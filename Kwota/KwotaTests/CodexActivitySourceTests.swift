//
//  CodexActivitySourceTests.swift
//  KwotaTests
//

import XCTest
import Combine
import AppKit
@testable import Kwota

@MainActor
final class CodexActivitySourceTests: XCTestCase {
    private var bag = Set<AnyCancellable>()

    override func tearDown() {
        bag.removeAll()
        super.tearDown()
    }

    private func drain() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private let sessionPath =
        "/Users/x/.codex/sessions/2026/05/20/rollout-2026-05-20T10-47-14-abc.jsonl"

    func testEmitsWhenLive() async {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(isLive: { true }, makeFileEvents: { stream }, clock: { fixedDate }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(sessionPath)
        await drain()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.provider, .codex)
        XCTAssertEqual(received.first?.date, fixedDate)
        cont.finish(); source.stop()
    }

    func testNoEmitWhenNotLive() async {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(isLive: { false }, makeFileEvents: { stream }, clock: { Date() }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(sessionPath)
        await drain()
        XCTAssertTrue(received.isEmpty)
        cont.finish(); source.stop()
    }

    func testNonSessionPathIgnored() async {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(isLive: { true }, makeFileEvents: { stream }, clock: { Date() }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield("/Users/x/.codex/history.jsonl")
        cont.yield("/Users/x/.codex/log/codex-tui.log")
        await drain()
        XCTAssertTrue(received.isEmpty)
        cont.finish(); source.stop()
    }

    func testLiveToggledMidStream() async {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var live = false
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(isLive: { live }, makeFileEvents: { stream }, clock: { Date() }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(sessionPath); await drain()
        XCTAssertEqual(received.count, 0)
        live = true
        cont.yield(sessionPath); await drain()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.provider, .codex)
        cont.finish(); source.stop()
    }

    // MARK: content-aware agent-response emission

    private func tempRolloutFile() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexsrc-\(UUID().uuidString)/sessions/2026/05/31", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rollout-test.jsonl")
    }

    private func assistantLine(_ iso: String) -> String {
        "{\"timestamp\":\"\(iso)\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\"}}\n"
    }

    func testEmitsAgentResponseForNewAssistantLine() async throws {
        let file = tempRolloutFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try "{\"type\":\"session_meta\"}\n".write(to: file, atomically: true, encoding: .utf8)

        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(isLive: { true }, makeFileEvents: { stream }, clock: { Date() }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        cont.yield(file.path); await drain()   // first sight → snapshot EOF, no agentResponse
        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 0)

        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = Date(timeIntervalSince1970: 1_780_000_123)
        try ("{\"type\":\"session_meta\"}\n" + assistantLine(iso.string(from: date)))
            .write(to: file, atomically: true, encoding: .utf8)
        cont.yield(file.path); await drain()

        let responses = received.filter { $0.kind == .agentResponse }
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.provider, .codex)
        XCTAssertEqual(responses.first?.date.timeIntervalSince1970 ?? 0,
                       date.timeIntervalSince1970, accuracy: 1)
        cont.finish(); source.stop()
    }

    func testNonAssistantAppendEmitsNoAgentResponse() async throws {
        let file = tempRolloutFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try "{\"type\":\"session_meta\"}\n".write(to: file, atomically: true, encoding: .utf8)

        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(isLive: { true }, makeFileEvents: { stream }, clock: { Date() }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(file.path); await drain()

        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let user = "{\"timestamp\":\"\(iso.string(from: Date()))\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\"}}\n"
        try ("{\"type\":\"session_meta\"}\n" + user).write(to: file, atomically: true, encoding: .utf8)
        cont.yield(file.path); await drain()

        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 0)
        XCTAssertTrue(received.contains { $0.kind == .fileWrite })   // awake still pulses
        cont.finish(); source.stop()
    }

    func testFirstSightDoesNotReplayHistory() async throws {
        let file = tempRolloutFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try (assistantLine(iso.string(from: Date())) + assistantLine(iso.string(from: Date())))
            .write(to: file, atomically: true, encoding: .utf8)

        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(isLive: { true }, makeFileEvents: { stream }, clock: { Date() }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(file.path); await drain()

        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 0)  // backfill already has these
        cont.finish(); source.stop()
    }

    /// A session file CREATED AFTER start() (the companion spawning Codex
    /// mid-run) that already holds a reply when FSEvents first reports it must
    /// have that reply read on first sight — launch backfill never saw the file,
    /// so the old "snapshot EOF" left it invisible on the chart until relaunch.
    func testFirstSightOfPostStartFileReadsExistingReplies() async throws {
        let file = tempRolloutFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        // Fixed past clock → startedAt sits well before the file's real-now
        // creation date, so it reliably reads as "created after start".
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: { stream },
            clock: { Date(timeIntervalSince1970: 1_000_000) },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        await drain()

        // File appears only now, already containing a reply.
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try assistantLine(iso.string(from: Date())).write(to: file, atomically: false, encoding: .utf8)
        cont.yield(file.path); await drain()

        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 1,
                       "first sight of a post-launch session must read its existing replies, not snapshot them away")
        cont.finish(); source.stop()
    }

    // MARK: FSEvents-stall resilience (poll backstop + wake re-arm)

    /// After FSEvents first-discovers a file then goes silent (the post-sleep
    /// stall that froze the live chart), the poll backstop must still pick up new
    /// appends to that already-known file.
    func testPollBackstopCatchesAppendsWhenStreamGoesSilent() async throws {
        let file = tempRolloutFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try "{\"type\":\"session_meta\"}\n".write(to: file, atomically: false, encoding: .utf8)

        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: { stream }, clock: { Date() },
            pollInterval: 0.2, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(file.path); await drain()   // FSEvents first-sights the file (offset set)
        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 0)

        // Append a reply WITHOUT yielding a new FSEvents path — simulate a stall.
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(assistantLine(iso.string(from: Date())).data(using: .utf8)!)
        try handle.close()

        try await Task.sleep(nanoseconds: 600_000_000)   // let ≥1 poll tick fire
        await drain()

        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 1)
        cont.finish(); source.stop()
    }

    /// A wake notification must re-arm the FSEvents stream — rebuild it via the
    /// factory — so delivery resumes after a sleep that stalled the old stream.
    func testWakeNotificationReArmsStream() async {
        let center = NotificationCenter()
        var continuations: [AsyncStream<String>.Continuation] = []
        var streamCount = 0
        let make: () -> AsyncStream<String> = {
            streamCount += 1
            return AsyncStream<String> { continuations.append($0) }
        }
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: make, clock: { Date() },
            pollInterval: 60, notificationCenter: center)
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        await drain()
        XCTAssertEqual(streamCount, 1)

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await drain()
        XCTAssertEqual(streamCount, 2, "wake should rebuild the FSEvents stream")

        // The old stream must be torn down, not merely abandoned: events yielded
        // to it after re-arm must be ignored (its consume task was cancelled).
        let beforeOld = received.count
        continuations.first?.yield("/Users/x/.codex/sessions/rollout-old.jsonl")
        await drain()
        XCTAssertEqual(received.count, beforeOld, "events from the torn-down stream must be ignored")

        // The freshly-armed stream is the one now being consumed.
        continuations.last?.yield("/Users/x/.codex/sessions/rollout-z.jsonl")
        await drain()
        XCTAssertTrue(received.contains { $0.kind == .fileWrite })
        source.stop()
    }

    /// A rollout file created entirely during an FSEvents blackout (never yielded
    /// through the stream, so it's not a known path) must still be discovered by
    /// the poll's untracked-file scan and its replies emitted.
    func testDiscoversUntrackedFileCreatedDuringBlackout() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexhome-\(UUID().uuidString)", isDirectory: true)
        let sessions = home.appendingPathComponent(".codex/sessions/2026/06/02", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let stream = AsyncStream<String> { _ in }   // FSEvents never yields → blackout
        var received: [ActivityEvent] = []
        // Fixed past clock → `startedAt` (the discovery cutoff) sits well before
        // the file's real-now line timestamps, so second-flooring can't drop them.
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: { stream },
            clock: { Date(timeIntervalSince1970: 1_000_000) },
            scanner: ProviderActivityBackfill.codex(home: home),
            pollInterval: 0.2, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        await drain()

        // Brand-new file written AFTER start() (mtime ≥ startedAt), reply stamped
        // now — never announced via FSEvents.
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let file = sessions.appendingPathComponent("rollout-blackout.jsonl")
        try assistantLine(iso.string(from: Date())).write(to: file, atomically: false, encoding: .utf8)

        try await Task.sleep(nanoseconds: 600_000_000)   // ≥1 poll → discovery scan
        await drain()

        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 1)
        source.stop()
    }

    // MARK: watchRoots resolution (cold-start fix)

    func test_watchRoots_prefersSessionsWhenPresent() {
        let home = URL(fileURLWithPath: "/Users/x")
        let exists: Set<String> = ["/Users/x/.codex/sessions", "/Users/x/.codex"]
        XCTAssertEqual(
            CodexActivitySource.watchRoots(home: home) { exists.contains($0) },
            ["/Users/x/.codex/sessions"]
        )
    }

    func test_watchRoots_fallsBackToCodexDir() {
        let home = URL(fileURLWithPath: "/Users/x")
        let exists: Set<String> = ["/Users/x/.codex"]
        XCTAssertEqual(
            CodexActivitySource.watchRoots(home: home) { exists.contains($0) },
            ["/Users/x/.codex"]
        )
    }

    func test_watchRoots_emptyWhenCodexAbsent() {
        let home = URL(fileURLWithPath: "/Users/x")
        XCTAssertTrue(
            CodexActivitySource.watchRoots(home: home) { _ in false }.isEmpty
        )
    }

    // MARK: app-server WAL bumps (debounced agent-response signal)
    //
    // `codex app-server` (used by the Claude Code Codex plugin) persists to
    // `~/.codex/logs_*.sqlite` instead of rollout JSONL — sessions/ stays cold
    // even though the model is replying. Watch the WAL filename via FSEvents
    // (passive, no IO) and coalesce rapid bumps into one `.agentResponse`.

    private let logsWALPath = "/Users/x/.codex/logs_2.sqlite-wal"

    func testWALEventEmitsAgentResponseAfterDebounce() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: { stream }, clock: { fixedDate },
            isClaudeCodexCompanionRunning: { true },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        cont.yield(logsWALPath)
        await drain()
        XCTAssertTrue(received.isEmpty, "no emit before debounce flush")

        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()

        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 1)
        XCTAssertEqual(received.filter { $0.kind == .fileWrite }.count, 1)
        XCTAssertEqual(received.first { $0.kind == .agentResponse }?.date, fixedDate)
        XCTAssertEqual(received.first { $0.kind == .agentResponse }?.provider, .codex)
        cont.finish(); source.stop()
    }

    func testRapidWALEventsCoalesceToSingleEvent() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: { stream }, clock: { Date() },
            isClaudeCodexCompanionRunning: { true },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        for _ in 0..<5 {
            cont.yield(logsWALPath)
            try? await Task.sleep(nanoseconds: 50_000_000)   // 5 bumps in 250ms
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()

        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 1,
                       "burst of WAL bumps within debounce window must collapse to one event")
        cont.finish(); source.stop()
    }

    func testWALIgnoredWhenNotLive() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { false }, makeFileEvents: { stream }, clock: { Date() },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        cont.yield(logsWALPath)
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()

        XCTAssertTrue(received.isEmpty)
        cont.finish(); source.stop()
    }

    /// `isLive` may flip false after a WAL event is scheduled but before the
    /// debounce flush fires — the flush must re-check and skip.
    func testWALFlushReChecksLiveAtFireTime() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var live = true
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { live }, makeFileEvents: { stream }, clock: { Date() },
            isClaudeCodexCompanionRunning: { true },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        cont.yield(logsWALPath)
        await drain()
        live = false   // user signs out within the 500ms window
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()

        XCTAssertTrue(received.isEmpty)
        cont.finish(); source.stop()
    }

    /// `/codex` slash command spawns `node codex-companion.mjs` as a Bash-tool
    /// child of Claude Code, alive only while the call is in flight. Its
    /// presence is a precise "user is actively driving codex" bridge — must
    /// trust WAL bumps even with no rollout JSONL append and no recent Claude
    /// activity, since a long `/codex` call can outlast the Claude bracket.
    func testWALTrustedWhileClaudeCodexCompanionRunning() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: { stream }, clock: { Date() },
            isClaudeCodexCompanionRunning: { true },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        cont.yield(logsWALPath)
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()

        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 1,
                       "companion running must keep WAL trusted even with no rollout/claude precedent")
        cont.finish(); source.stop()
    }

    /// Regression for adversarial review: companion trust must be captured at
    /// WAL-bump OBSERVATION time, not at flush fire time. `scheduleWALFlush`
    /// debounces (0.5s) and rapid bumps cancel + reschedule. A real /codex burst
    /// that ends with the companion exiting before the final debounce fires
    /// would otherwise drop the keep-awake emit. Setting `pendingFlushTrusted`
    /// when each bump is observed keeps the flush emitting as long as some
    /// bump in the burst saw the companion alive.
    func testWALEmittedWhenCompanionWasAliveAtBumpButExitedBeforeFlush() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var companionAlive = true
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: { stream }, clock: { Date() },
            isClaudeCodexCompanionRunning: { companionAlive },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        cont.yield(logsWALPath)
        await drain()
        companionAlive = false   // companion exits within the 500ms debounce
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()

        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 1,
                       "companion alive at bump observation must trust the emit even if it exits during debounce")
        cont.finish(); source.stop()
    }

    /// Companion was never alive at any WAL observation, so subsequent orphan
    /// bumps must not emit. Pairs with the above: snapshot-at-observation must
    /// not retroactively open the gate just because companion was alive at some
    /// past, unrelated moment in another process.
    func testWALIgnoredWhenCompanionNeverObservedAtBumpTime() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: { stream }, clock: { Date() },
            isClaudeCodexCompanionRunning: { false },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        cont.yield(logsWALPath)
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()

        XCTAssertTrue(received.isEmpty,
                      "WAL bump observed with no companion alive must not emit")
        cont.finish(); source.stop()
    }

    /// Regression for adversarial-review finding: Claude's global `.agentResponse`
    /// is NOT a valid trust signal for the shared `logs_*.sqlite-wal`. The WAL is
    /// machine-wide, so an unrelated Claude conversation (any project) plus a
    /// background WAL bump (orphan broker from another project) must NOT emit a
    /// keep-awake pulse. Only a Codex-scoped signal (rollout JSONL append or live
    /// `codex-companion.mjs` process) is allowed to open the gate.
    func testWALIgnoredWhenOnlyUnrelatedClaudeActivityIsRecent() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        // Companion is NOT running (the user is not driving `/codex`); the only
        // "recent" thing is unrelated Claude chat happening in some other project.
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: { stream }, clock: { Date() },
            isClaudeCodexCompanionRunning: { false },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        // Orphan WAL bumps arriving from leftover brokers in other worktrees.
        cont.yield(logsWALPath)
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()

        XCTAssertTrue(received.isEmpty,
                      "Claude global activity must NOT bridge the shared WAL gate — only a live codex-companion.mjs may")
        cont.finish(); source.stop()
    }

    /// Regression for adversarial review finding: companion trust must apply
    /// only to the currently debounced WAL burst, not to all bumps for some
    /// rolling time window. After a real /codex burst's flush fires and clears
    /// the flag, a later orphan WAL bump observed with the companion gone must
    /// NOT emit — otherwise the prior call's authorization leaks into orphan
    /// noise from other-project zombies and the Mac stays awake indefinitely.
    func testPerBurstTrustDoesNotLeakAcrossBursts() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var companionAlive = true
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: { stream }, clock: { Date() },
            isClaudeCodexCompanionRunning: { companionAlive },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        // Burst 1: companion alive → flush emits and clears trust
        cont.yield(logsWALPath)
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()
        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 1,
                       "burst 1 with companion alive must emit")
        received.removeAll()

        // Companion exits between bursts (call ended).
        companionAlive = false

        // Burst 2 (orphan zombie bump): no emit — burst 1's authorization
        // must not carry over.
        cont.yield(logsWALPath)
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()
        XCTAssertTrue(received.isEmpty,
                      "burst 2 with companion gone must NOT inherit burst 1's trust")
        cont.finish(); source.stop()
    }

    /// Regression for adversarial review: a trusted burst whose flush is SKIPPED
    /// (because `isLive()` flipped false during the 0.5s debounce) must still
    /// clear the trust flag. Otherwise a later orphan WAL bump observed after
    /// the user signs back in (companion gone, only zombies bumping) would
    /// inherit the stale `true` and falsely emit — reopening the bug per-burst
    /// trust was designed to prevent.
    func testStaleTrustClearedWhenLivenessLostDuringDebounce() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var live = true
        var companion = true
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { live }, makeFileEvents: { stream }, clock: { Date() },
            isClaudeCodexCompanionRunning: { companion },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        // Burst 1: companion alive → pendingFlushTrusted=true
        cont.yield(logsWALPath)
        await drain()

        // User signs out of Codex BEFORE the debounce fires.
        live = false
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()
        XCTAssertTrue(received.isEmpty, "flush skipped due to !isLive()")

        // User signs back in; companion is gone (no /codex in flight).
        live = true
        companion = false

        // Orphan WAL bump arrives from a zombie broker.
        cont.yield(logsWALPath)
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()

        XCTAssertTrue(received.isEmpty,
                      "trust from pre-sign-out burst must be cleared on the skipped flush — orphan bump after sign-in must not emit")
        cont.finish(); source.stop()
    }

    /// Regression for system-sleep edge case: when the lid closes during the
    /// 0.5s debounce, `Task.sleep` tracks wall-clock so the timer "expires"
    /// mid-sleep and the body resumes only at wake — potentially hours later.
    /// Without the staleness guard, that resume would emit a fresh keep-awake
    /// event for an arbitrarily-old observation, resetting the supervisor's
    /// idle timer at wake for stale activity. The injected clock here jumps
    /// forward AFTER scheduling but BEFORE the body runs, mimicking the
    /// wall-clock advance that occurs during system sleep.
    func testWALFlushSkipsEmitWhenSchedulingClockIsStale() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var clockTime = Date(timeIntervalSince1970: 1_700_000_000)
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: { stream }, clock: { clockTime },
            isClaudeCodexCompanionRunning: { true },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        // Burst observed at t=0: companion alive → trusted, schedule flush
        cont.yield(logsWALPath)
        await drain()

        // Simulate system sleep: wall clock jumps an hour while the debounce
        // task is "sleeping". Real production behavior — Task.sleep tracks
        // wall time, body would resume at wake with `now` far past schedule.
        clockTime = clockTime.addingTimeInterval(3600)

        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()

        XCTAssertTrue(received.isEmpty,
                      "WAL flush body resumed long after scheduling (system-sleep simulation) must skip emit")
        cont.finish(); source.stop()
    }

    /// Regression for adversarial review: a `stop()` while a flush is pending
    /// must clear the trust flag so the next `start()` cycle begins fresh. A
    /// stale `true` would let the first WAL bump after restart emit even with
    /// no companion running.
    func testStaleTrustClearedAcrossStopStartCycle() async throws {
        final class Holder { var cont: AsyncStream<String>.Continuation? }
        let holder = Holder()
        let makeStream: () -> AsyncStream<String> = {
            AsyncStream { holder.cont = $0 }
        }
        var companion = true
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: makeStream, clock: { Date() },
            isClaudeCodexCompanionRunning: { companion },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)

        source.start()
        holder.cont?.yield(logsWALPath)   // companion alive → trust set
        await drain()

        // stop() before the 500ms debounce fires.
        source.stop()
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()
        XCTAssertTrue(received.isEmpty, "stop() cancels the pending flush")

        // Restart with companion gone (different session, no /codex).
        companion = false
        source.start()
        holder.cont?.yield(logsWALPath)   // pure orphan bump
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()

        XCTAssertTrue(received.isEmpty,
                      "trust from the burst before stop() must not survive into the new start() cycle")
        source.stop()
    }

    /// Only `logs_*.sqlite-wal` bumps count as agent activity. State/goals/
    /// memories WALs and the plain `.sqlite` data file (without `-wal`) must
    /// be ignored — they aren't reliable agent-response signals.
    func testNonLogsWALPathsIgnored() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: { stream }, clock: { Date() },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        cont.yield("/Users/x/.codex/state_5.sqlite-wal")
        cont.yield("/Users/x/.codex/goals_1.sqlite-wal")
        cont.yield("/Users/x/.codex/memories_1.sqlite-wal")
        cont.yield("/Users/x/.codex/logs_2.sqlite")           // not -wal
        cont.yield("/Users/x/.codex/logs_2.sqlite-shm")       // shared-mem index, not WAL
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()

        XCTAssertTrue(received.isEmpty)
        cont.finish(); source.stop()
    }

    func testStopCancelsPendingWALFlush() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = CodexActivitySource(
            isLive: { true }, makeFileEvents: { stream }, clock: { Date() },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        cont.yield(logsWALPath)
        await drain()
        source.stop()                                    // before the 500ms flush
        try await Task.sleep(nanoseconds: 700_000_000)
        await drain()

        XCTAssertTrue(received.isEmpty)
        cont.finish()
    }

    // MARK: fsEventsRoots (broader watch surface for app-server WAL files)

    /// FSEvents must watch `~/.codex` (broad) — not the narrower `sessions/`
    /// — so the same stream sees both rollout JSONL appends AND
    /// `logs_*.sqlite-wal` bumps. The scanner's narrow root is unrelated.
    func test_fsEventsRoots_returnsCodexDirWhenPresent() {
        let home = URL(fileURLWithPath: "/Users/x")
        let exists: Set<String> = ["/Users/x/.codex", "/Users/x/.codex/sessions"]
        XCTAssertEqual(
            CodexActivitySource.fsEventsRoots(home: home) { exists.contains($0) },
            ["/Users/x/.codex"]
        )
    }

    func test_fsEventsRoots_emptyWhenCodexAbsent() {
        let home = URL(fileURLWithPath: "/Users/x")
        XCTAssertTrue(
            CodexActivitySource.fsEventsRoots(home: home) { _ in false }.isEmpty
        )
    }

    // MARK: - WAL stat-poll backstop
    //
    // FSEvents is unreliable for SQLite WAL writes that overwrite preallocated
    // space (the common case when `codex app-server` commits within an
    // already-grown WAL). A separate stat-only poll catches what the stream
    // misses; these tests pin the contract: pre-launch mtime never replays,
    // an advance fires exactly one event, and the FSEvent path suppresses the
    // next poll tick from double-counting the same bump.

    /// A pre-existing WAL whose mtime is older than `start()` must not
    /// re-fire on the first poll tick — that's not a turn, just whatever
    /// Codex did before Kwota launched. We seed `logsWALMtimes` at start so
    /// the very first mtime read becomes the baseline.
    func test_walPoll_seedsBaseline_andDoesNotFireOnFirstTick() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let walPath = "/Users/x/.codex/logs_2.sqlite-wal"
        let initialMtime = Date(timeIntervalSince1970: 1_700_000_000)
        let probedMtime = initialMtime
        let source = CodexActivitySource(
            isLive: { true },
            makeFileEvents: { stream },
            clock: { Date() },
            walPollInterval: 0.05,
            walProbe: { [(path: walPath, mtime: probedMtime)] },
            notificationCenter: NotificationCenter()
        )
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        // Run several poll ticks with the same mtime — must stay silent.
        try await Task.sleep(nanoseconds: 300_000_000)
        await drain()
        XCTAssertTrue(received.isEmpty, "stable mtime must not fire")
        cont.finish(); source.stop()
    }

    /// When the WAL mtime advances after `start()`, the poll must fire one
    /// agent-response (and one file-write) via the same debounce path
    /// FSEvents takes.
    func test_walPoll_firesOnMtimeAdvance() async throws {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let walPath = "/Users/x/.codex/logs_2.sqlite-wal"
        // Wrap mtime in a reference so the closure sees the latest write.
        final class Box { var mtime = Date(timeIntervalSince1970: 1_700_000_000) }
        let box = Box()
        let source = CodexActivitySource(
            isLive: { true },
            makeFileEvents: { stream },
            clock: { Date() },
            walPollInterval: 0.05,
            walProbe: { [(path: walPath, mtime: box.mtime)] },
            isClaudeCodexCompanionRunning: { true },
            notificationCenter: NotificationCenter()
        )
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        // Let the baseline seed and a couple of stable ticks land.
        try await Task.sleep(nanoseconds: 150_000_000)
        await drain()
        XCTAssertTrue(received.isEmpty, "stable baseline must not fire")

        // Advance the mtime; next poll should detect and schedule a flush.
        box.mtime = Date(timeIntervalSince1970: 1_700_000_010)
        try await Task.sleep(nanoseconds: 800_000_000)   // tick + 0.5s debounce
        await drain()

        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 1)
        XCTAssertEqual(received.filter { $0.kind == .fileWrite }.count, 1)
        cont.finish(); source.stop()
    }

    /// An FSEvent for a WAL path must update `logsWALMtimes` so the next
    /// stat-poll tick does not refire the same bump.
    func test_walFSEventSuppressesPollDoubleFire() async throws {
        // Use a real temp WAL file so the FSEvent branch's stat call can read
        // its mtime; the WAL probe also reflects the same file.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwota-codex-wal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let walURL = tmp.appendingPathComponent("logs_2.sqlite-wal")
        FileManager.default.createFile(atPath: walURL.path, contents: Data("seed".utf8))
        // Make the seed mtime distinctly in the past.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: walURL.path)

        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        // walProbe stats the real file so the FSEvent's mtime-store matches.
        let source = CodexActivitySource(
            isLive: { true },
            makeFileEvents: { stream },
            clock: { Date() },
            walPollInterval: 0.05,
            walProbe: {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: walURL.path),
                      let mtime = attrs[.modificationDate] as? Date else { return [] }
                return [(path: walURL.path, mtime: mtime)]
            },
            isClaudeCodexCompanionRunning: { true },
            notificationCenter: NotificationCenter()
        )
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()

        // Bump the WAL's mtime, then yield the FSEvent. The FSEvent branch
        // will stat the file and record the new mtime, suppressing the next
        // poll-tick from refiring.
        let bumped = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: bumped], ofItemAtPath: walURL.path)
        cont.yield(walURL.path)

        try await Task.sleep(nanoseconds: 800_000_000)   // debounce + a few poll ticks
        await drain()

        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 1,
                       "FSEvent + same-bump poll must collapse to a single event")
        cont.finish(); source.stop()
    }
}
