//
//  JSONLActivitySource.swift
//  Kwota
//

import Foundation
import Combine

/// Why a provider's activity fired. `fileWrite` is any append to a watched
/// transcript (drives keep-awake — sensitive, content-blind). `agentResponse`
/// is a parsed agent reply (drives the chart — comparable across providers, the
/// same unit Claude already counts).
enum ActivityKind: Equatable {
    case fileWrite
    case agentResponse
}

/// One observed work event from a provider, with the time it happened.
struct ActivityEvent: Equatable {
    let date: Date
    let provider: ProviderID
    let kind: ActivityKind
}

@MainActor
protocol ActivitySource: AnyObject {
    var activityPublisher: AnyPublisher<ActivityEvent, Never> { get }
    /// Begin observing. No-op for sources that observe from `init`.
    func start()
    /// Stop observing and release resources.
    func stop()
}

extension ActivitySource {
    func start() {}
    func stop() {}
}

/// Claude activity: forwards UsageMonitor JSONL-append ticks as `.claude` events.
@MainActor
final class UsageMonitorActivitySource: ActivitySource {
    private let subject = PassthroughSubject<ActivityEvent, Never>()
    private var bag = Set<AnyCancellable>()

    var activityPublisher: AnyPublisher<ActivityEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    init(usage: UsageMonitor) {
        // `lastEvents` is reassigned on every UsageMonitor.tick(). It only
        // changes when `newEvents` is non-empty (see UsageMonitor.tick()),
        // so an emission here means at least one fresh JSONL append since
        // the last poll. Forward the newest event's timestamp.
        usage.$lastEvents
            .receive(on: RunLoop.main)
            .sink { [weak self] events in
                guard let last = events.last else { return }
                self?.subject.send(ActivityEvent(date: last.timestamp, provider: .claude, kind: .agentResponse))
            }
            .store(in: &bag)
    }
}
