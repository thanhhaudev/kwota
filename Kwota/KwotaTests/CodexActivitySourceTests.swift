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
}
