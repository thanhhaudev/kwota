//
//  FakeBatteryMonitor.swift
//  KwotaTests
//

import Foundation
import Combine
@testable import Kwota

@MainActor
final class FakeBatteryMonitor: BatteryMonitoring {
    private let subject: CurrentValueSubject<BatteryReading, Never>

    init(initial: BatteryReading = BatteryReading(isOnBattery: false, percent: nil)) {
        self.subject = CurrentValueSubject(initial)
    }

    var reading: BatteryReading { subject.value }
    var readingPublisher: AnyPublisher<BatteryReading, Never> {
        subject.eraseToAnyPublisher()
    }
    func start() {}

    func emit(_ next: BatteryReading) { subject.send(next) }
}
