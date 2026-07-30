//
//  BatteryMonitor.swift
//  Kwota

import Foundation
import IOKit.ps
import Combine

/// Nonisolated + Sendable because `AwakeWatchdog` samples this from its own
/// queue. Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` an unannotated
/// struct is MainActor-isolated and could not cross that boundary.
nonisolated struct BatteryReading: Equatable, Sendable {
    /// `false` when the Mac has no battery (desktop) or is plugged in.
    var isOnBattery: Bool
    /// `nil` when the Mac has no battery hardware.
    var percent: Int?
}

@MainActor
protocol BatteryMonitoring: AnyObject {
    var reading: BatteryReading { get }
    /// Fires whenever `reading` changes. Stays alive for the monitor's lifetime.
    var readingPublisher: AnyPublisher<BatteryReading, Never> { get }
    func start()
}

@MainActor
final class IOPowerSourcesBatteryMonitor: BatteryMonitoring {
    private let subject: CurrentValueSubject<BatteryReading, Never>
    private var runLoopSource: CFRunLoopSource?

    init() {
        self.subject = CurrentValueSubject(PowerSourceSampler.snapshot())
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    var reading: BatteryReading { subject.value }
    var readingPublisher: AnyPublisher<BatteryReading, Never> {
        subject.eraseToAnyPublisher()
    }

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOPowerSourceCallbackType = { rawCtx in
            guard let raw = rawCtx else { return }
            let monitor = Unmanaged<IOPowerSourcesBatteryMonitor>
                .fromOpaque(raw).takeUnretainedValue()
            Task { @MainActor in monitor.refresh() }
        }
        let source = IOPSNotificationCreateRunLoopSource(cb, context).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        refresh()
    }

    private func refresh() {
        let snap = PowerSourceSampler.snapshot()
        guard snap != subject.value else { return }
        subject.send(snap)
    }
}
