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

    private(set) var popoverOpenCalls: [Bool] = []
    private(set) var assertionHeldCalls: [Bool] = []

    func setPopoverOpen(_ open: Bool) { popoverOpenCalls.append(open) }
    func setAssertionHeld(_ held: Bool) { assertionHeldCalls.append(held) }

    func emit(_ next: BatteryReading) { subject.send(next) }
}
