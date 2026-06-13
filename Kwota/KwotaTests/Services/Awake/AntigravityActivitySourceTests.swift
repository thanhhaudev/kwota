//
//  AntigravityActivitySourceTests.swift
//  KwotaTests
//

import XCTest
import Combine
import AppKit
@testable import Kwota

@MainActor
final class AntigravityActivitySourceTests: XCTestCase {
    private var bag = Set<AnyCancellable>()
    private var tempDirs: [URL] = []

    override func tearDown() {
        bag.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    /// Write a real transcript under a `brain/.../transcript.jsonl` path and
    /// return that path. When `eval` is true the USER_INPUT carries Kwota's
    /// cache-eval signature, so the source should treat the whole session as its
    /// own evaluation and emit nothing.
    private func makeTranscriptOnDisk(eval: Bool) -> String {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agysrc-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(base)
        let logs = base.appendingPathComponent(
            "antigravity-cli/brain/s/.system_generated/logs", isDirectory: true)
        try! FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let userContent = eval
            ? "You are a \(CacheEvaluationPrompts.activitySignature) local cache folders."
            : "Refactor the JSONL parser"
        let body = "{\"type\":\"USER_INPUT\",\"content\":\"\(userContent)\"}\n"
            + "{\"type\":\"PLANNER_RESPONSE\",\"created_at\":\"2026-06-13T08:00:00Z\"}\n"
        let url = logs.appendingPathComponent("transcript.jsonl")
        try! body.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func drain() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private let transcriptPath =
        "/Users/x/.gemini/antigravity/brain/abc/.system_generated/logs/transcript.jsonl"

    // MARK: stream / filter behavior

    func testEmitsOnTranscriptAppendWhenLive() async {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        var received: [ActivityEvent] = []
        let source = AntigravityActivitySource(isLive: { true }, makeFileEvents: { stream }, clock: { fixedDate }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(transcriptPath)
        await drain()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.provider, .antigravity)
        XCTAssertEqual(received.first?.date, fixedDate)
        cont.finish(); source.stop()
    }

    func testNoEmitWhenNotLive() async {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = AntigravityActivitySource(isLive: { false }, makeFileEvents: { stream }, clock: { Date() }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(transcriptPath)
        await drain()
        XCTAssertTrue(received.isEmpty)
        cont.finish(); source.stop()
    }

    func testNonTranscriptPathIgnored() async {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = AntigravityActivitySource(isLive: { true }, makeFileEvents: { stream }, clock: { Date() }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield("/Users/x/.gemini/antigravity/conversations/abc.db-wal")
        cont.yield("/Users/x/.gemini/antigravity/agyhub_summaries_proto.pb")
        await drain()
        XCTAssertTrue(received.isEmpty)
        cont.finish(); source.stop()
    }

    /// A `transcript.jsonl` NOT under a `brain/` tree must be ignored — guards
    /// the broadened watch root (which may be `~/.gemini`) against stray
    /// transcripts elsewhere in the tree.
    func testTranscriptOutsideBrainIgnored() async {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = AntigravityActivitySource(isLive: { true }, makeFileEvents: { stream }, clock: { Date() }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield("/Users/x/.gemini/history/transcript.jsonl")
        await drain()
        XCTAssertTrue(received.isEmpty)
        cont.finish(); source.stop()
    }

    func testMultipleTranscriptAppendsEmitEach() async {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = AntigravityActivitySource(isLive: { true }, makeFileEvents: { stream }, clock: { Date() }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(transcriptPath); await drain()
        cont.yield(transcriptPath); await drain()
        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received.allSatisfy { $0.provider == .antigravity })
        cont.finish(); source.stop()
    }

    func testLiveToggledMidStream() async {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var live = false
        var received: [ActivityEvent] = []
        let source = AntigravityActivitySource(isLive: { live }, makeFileEvents: { stream }, clock: { Date() }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(transcriptPath); await drain()
        XCTAssertEqual(received.count, 0)
        live = true
        cont.yield(transcriptPath); await drain()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.provider, .antigravity)
        cont.finish(); source.stop()
    }

    // MARK: content-aware agent-response emission

    private func tempTranscriptFile() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("antisrc-\(UUID().uuidString)/brain/abc/.system_generated/logs", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcript.jsonl")
    }

    private func plannerLine(_ iso: String) -> String {
        "{\"created_at\":\"\(iso)\",\"type\":\"PLANNER_RESPONSE\"}\n"
    }

    func testEmitsAgentResponseForNewPlannerLine() async throws {
        let file = tempTranscriptFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try "{\"type\":\"USER_INPUT\"}\n".write(to: file, atomically: true, encoding: .utf8)

        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = AntigravityActivitySource(isLive: { true }, makeFileEvents: { stream }, clock: { Date() }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(file.path); await drain()   // first sight → snapshot EOF
        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 0)

        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let date = Date(timeIntervalSince1970: 1_780_000_200)
        try ("{\"type\":\"USER_INPUT\"}\n" + plannerLine(iso.string(from: date)))
            .write(to: file, atomically: true, encoding: .utf8)
        cont.yield(file.path); await drain()

        let responses = received.filter { $0.kind == .agentResponse }
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.provider, .antigravity)
        XCTAssertEqual(responses.first?.date.timeIntervalSince1970 ?? 0,
                       date.timeIntervalSince1970, accuracy: 1)
        cont.finish(); source.stop()
    }

    func testNonPlannerAppendEmitsNoAgentResponse() async throws {
        let file = tempTranscriptFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try "{\"type\":\"USER_INPUT\"}\n".write(to: file, atomically: true, encoding: .utf8)

        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = AntigravityActivitySource(isLive: { true }, makeFileEvents: { stream }, clock: { Date() }, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(file.path); await drain()

        try ("{\"type\":\"USER_INPUT\"}\n" + "{\"type\":\"EPHEMERAL_MESSAGE\"}\n")
            .write(to: file, atomically: true, encoding: .utf8)
        cont.yield(file.path); await drain()

        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 0)
        XCTAssertTrue(received.contains { $0.kind == .fileWrite })
        cont.finish(); source.stop()
    }

    // MARK: FSEvents-stall resilience (poll backstop + wake re-arm)

    /// After FSEvents first-discovers a transcript then goes silent (the
    /// post-sleep stall that froze the live chart), the poll backstop must still
    /// pick up new `PLANNER_RESPONSE` appends to that already-known transcript.
    func testPollBackstopCatchesAppendsWhenStreamGoesSilent() async throws {
        let file = tempTranscriptFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try "{\"type\":\"USER_INPUT\"}\n".write(to: file, atomically: false, encoding: .utf8)

        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        var received: [ActivityEvent] = []
        let source = AntigravityActivitySource(
            isLive: { true }, makeFileEvents: { stream }, clock: { Date() },
            pollInterval: 0.2, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(file.path); await drain()   // FSEvents first-sights the transcript (offset set)
        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 0)

        // Append a reply WITHOUT yielding a new FSEvents path — simulate a stall.
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(plannerLine(iso.string(from: Date())).data(using: .utf8)!)
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
        let source = AntigravityActivitySource(
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
        continuations.first?.yield("/Users/x/.gemini/antigravity/brain/old/transcript.jsonl")
        await drain()
        XCTAssertEqual(received.count, beforeOld, "events from the torn-down stream must be ignored")

        // The freshly-armed stream is the one now being consumed.
        continuations.last?.yield("/Users/x/.gemini/antigravity/brain/z/transcript.jsonl")
        await drain()
        XCTAssertTrue(received.contains { $0.kind == .fileWrite })
        source.stop()
    }

    /// A transcript created entirely during an FSEvents blackout (never yielded
    /// through the stream, so it's not a known path) must still be discovered by
    /// the poll's untracked-file scan and its `PLANNER_RESPONSE`s emitted.
    func testDiscoversUntrackedFileCreatedDuringBlackout() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("antihome-\(UUID().uuidString)", isDirectory: true)
        let brain = home.appendingPathComponent(".gemini/antigravity/brain/abc/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let stream = AsyncStream<String> { _ in }   // FSEvents never yields → blackout
        var received: [ActivityEvent] = []
        // Fixed past clock → `startedAt` (the discovery cutoff) sits well before
        // the file's real-now line timestamps, so second-flooring can't drop them.
        let source = AntigravityActivitySource(
            isLive: { true }, makeFileEvents: { stream },
            clock: { Date(timeIntervalSince1970: 1_000_000) },
            scanner: ProviderActivityBackfill.antigravity(home: home),
            pollInterval: 0.2, notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        await drain()

        // Brand-new transcript written AFTER start() (mtime ≥ startedAt), reply
        // stamped now — never announced via FSEvents.
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let file = brain.appendingPathComponent("transcript.jsonl")
        try plannerLine(iso.string(from: Date())).write(to: file, atomically: false, encoding: .utf8)

        try await Task.sleep(nanoseconds: 600_000_000)   // ≥1 poll → discovery scan
        await drain()

        XCTAssertEqual(received.filter { $0.kind == .agentResponse }.count, 1)
        source.stop()
    }

    // MARK: watchRoots resolution (the cold-start fix)

    func test_watchRoots_prefersBrainWhenPresent() {
        let home = URL(fileURLWithPath: "/Users/x")
        let exists: Set<String> = [
            "/Users/x/.gemini/antigravity/brain",
            "/Users/x/.gemini/antigravity",
            "/Users/x/.gemini",
            "/Users/x/.gemini/antigravity-cli/brain",
            "/Users/x/.gemini/antigravity-cli",
        ]
        XCTAssertEqual(
            AntigravityActivitySource.watchRoots(home: home) { exists.contains($0) },
            ["/Users/x/.gemini/antigravity/brain",
             "/Users/x/.gemini/antigravity-cli/brain"]
        )
    }

    func test_watchRoots_fallsBackToAppDirThenGemini() {
        let home = URL(fileURLWithPath: "/Users/x")
        // IDE: app dir exists but no brain yet → app dir.
        // CLI: neither brain nor app dir → ~/.gemini.
        let exists: Set<String> = [
            "/Users/x/.gemini/antigravity",
            "/Users/x/.gemini",
        ]
        XCTAssertEqual(
            AntigravityActivitySource.watchRoots(home: home) { exists.contains($0) },
            ["/Users/x/.gemini/antigravity",
             "/Users/x/.gemini"]
        )
    }

    func test_watchRoots_dedupesWhenBothFallBackToGemini() {
        let home = URL(fileURLWithPath: "/Users/x")
        let exists: Set<String> = ["/Users/x/.gemini"]
        XCTAssertEqual(
            AntigravityActivitySource.watchRoots(home: home) { exists.contains($0) },
            ["/Users/x/.gemini"]
        )
    }

    func test_watchRoots_emptyWhenGeminiAbsent() {
        let home = URL(fileURLWithPath: "/Users/x")
        XCTAssertTrue(
            AntigravityActivitySource.watchRoots(home: home) { _ in false }.isEmpty
        )
    }

    // MARK: cache-eval suppression

    /// A transcript written by Kwota's own cache evaluation lands in the watched
    /// brain tree, but it isn't the user's work — the source emits nothing for it.
    func testSkipsKwotaCacheEvalTranscript() async {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        var received: [ActivityEvent] = []
        let source = AntigravityActivitySource(
            isLive: { true }, makeFileEvents: { stream }, clock: { past },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(makeTranscriptOnDisk(eval: true))
        await drain()
        XCTAssertTrue(received.isEmpty,
                      "Kwota's own cache-eval session must not surface on the chart")
        cont.finish(); source.stop()
    }

    /// A real Antigravity session beside it is still counted — the filter is
    /// content-specific, not a blanket mute of the antigravity-cli tree.
    func testEmitsForRealSessionTranscript() async {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        var received: [ActivityEvent] = []
        let source = AntigravityActivitySource(
            isLive: { true }, makeFileEvents: { stream }, clock: { past },
            notificationCenter: NotificationCenter())
        source.activityPublisher.sink { received.append($0) }.store(in: &bag)
        source.start()
        cont.yield(makeTranscriptOnDisk(eval: false))
        await drain()
        XCTAssertTrue(received.contains { $0.kind == .agentResponse },
                      "a real session's PLANNER_RESPONSE should be counted")
        cont.finish(); source.stop()
    }
}
