//
//  CompositeActivitySource.swift
//  Kwota
//

import Foundation
import Combine

/// Merges several provider activity sources into one stream and one lifecycle.
/// Live-account gating lives inside each child source, so this just fans in.
@MainActor
final class CompositeActivitySource: ActivitySource {
    private let sources: [ActivitySource]

    init(sources: [ActivitySource]) { self.sources = sources }

    var activityPublisher: AnyPublisher<ActivityEvent, Never> {
        Publishers.MergeMany(sources.map { $0.activityPublisher }).eraseToAnyPublisher()
    }

    func start() { sources.forEach { $0.start() } }
    func stop() { sources.forEach { $0.stop() } }
}
