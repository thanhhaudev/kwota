//
//  CompositeActivitySourceTests.swift
//  KwotaTests
//

import XCTest
import Combine
@testable import Kwota

@MainActor
final class CompositeActivitySourceTests: XCTestCase {
    @MainActor final class FakeSource: ActivitySource {
        let subject = PassthroughSubject<ActivityEvent, Never>()
        private(set) var startCount = 0
        private(set) var stopCount = 0
        var activityPublisher: AnyPublisher<ActivityEvent, Never> { subject.eraseToAnyPublisher() }
        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
    }

    func testMergeFansInEventsFromAllSources() {
        let a = FakeSource()
        let b = FakeSource()
        let composite = CompositeActivitySource(sources: [a, b])

        var received: [ActivityEvent] = []
        var bag = Set<AnyCancellable>()
        composite.activityPublisher
            .sink { received.append($0) }
            .store(in: &bag)

        let claudeDate = Date(timeIntervalSince1970: 1_000)
        let codexDate = Date(timeIntervalSince1970: 2_000)
        a.subject.send(ActivityEvent(date: claudeDate, provider: .claude, kind: .agentResponse))
        b.subject.send(ActivityEvent(date: codexDate, provider: .codex, kind: .agentResponse))

        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received.contains(ActivityEvent(date: claudeDate, provider: .claude, kind: .agentResponse)))
        XCTAssertTrue(received.contains(ActivityEvent(date: codexDate, provider: .codex, kind: .agentResponse)))
    }

    func testStartForwardedToAllSources() {
        let a = FakeSource()
        let b = FakeSource()
        let composite = CompositeActivitySource(sources: [a, b])

        composite.start()

        XCTAssertEqual(a.startCount, 1)
        XCTAssertEqual(b.startCount, 1)
    }

    func testStopForwardedToAllSources() {
        let a = FakeSource()
        let b = FakeSource()
        let composite = CompositeActivitySource(sources: [a, b])

        composite.stop()

        XCTAssertEqual(a.stopCount, 1)
        XCTAssertEqual(b.stopCount, 1)
    }
}
