//
//  InMemoryClock.swift
//  KwotaTests
//

import Foundation

final class InMemoryClock {
    private(set) var now: Date
    init(_ initial: Date) { self.now = initial }
    func advance(by interval: TimeInterval) { now.addTimeInterval(interval) }
    var dateProvider: () -> Date { { [weak self] in self?.now ?? Date() } }
}
