//
//  BatteryMonitor.swift
//  Kwota

import Foundation
import IOKit.ps
import Combine

struct BatteryReading: Equatable {
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
        self.subject = CurrentValueSubject(Self.snapshot())
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
        let snap = Self.snapshot()
        guard snap != subject.value else { return }
        subject.send(snap)
    }

    private static func snapshot() -> BatteryReading {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]

        // Walk the list once; pick the first battery source that yields a
        // capacity reading. Desktops produce an empty list and fall through
        // to the nil-percent reading.
        for ps in list {
            guard let dict = IOPSGetPowerSourceDescription(blob, ps).takeUnretainedValue()
                    as? [String: Any] else { continue }
            let state = dict[kIOPSPowerSourceStateKey] as? String
            let current = dict[kIOPSCurrentCapacityKey] as? Int
            let max = dict[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = current.map { max == 0 ? 0 : Int((Double($0) / Double(max)) * 100) }
            let isBattery = state == kIOPSBatteryPowerValue
            return BatteryReading(isOnBattery: isBattery, percent: percent)
        }
        return BatteryReading(isOnBattery: false, percent: nil)
    }
}
