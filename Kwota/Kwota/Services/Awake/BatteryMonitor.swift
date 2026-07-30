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
    /// Demand signals for the poll backstop. The monitor ORs them: the reading
    /// is consumed by the status UI while the popover is open, and by the
    /// battery-threshold decision while an assertion is held. With neither,
    /// nothing reads it and polling is pure waste.
    func setPopoverOpen(_ open: Bool)
    func setAssertionHeld(_ held: Bool)
}

@MainActor
final class IOPowerSourcesBatteryMonitor: BatteryMonitoring {
    private let subject: CurrentValueSubject<BatteryReading, Never>
    private var runLoopSource: CFRunLoopSource?

    private let pollInterval: TimeInterval
    private let sampler: @Sendable () -> BatteryReading
    private let installRunLoopSource: Bool

    private var isPopoverOpen = false
    private var isAssertionHeld = false
    /// Cancelled from `deinit`, which is nonisolated — same reason
    /// `AwakeSessionLog.pruneTask` carries this annotation.
    nonisolated(unsafe) private var pollTask: Task<Void, Never>?

    init(
        pollInterval: TimeInterval = 60,
        sampler: @escaping @Sendable () -> BatteryReading = PowerSourceSampler.snapshot,
        installRunLoopSource: Bool = true
    ) {
        self.pollInterval = pollInterval
        self.sampler = sampler
        self.installRunLoopSource = installRunLoopSource
        self.subject = CurrentValueSubject(sampler())
    }

    deinit {
        pollTask?.cancel()
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    var reading: BatteryReading { subject.value }
    var readingPublisher: AnyPublisher<BatteryReading, Never> {
        subject.eraseToAnyPublisher()
    }

    func start() {
        // Install once, then always take one reading. Folding the refresh into
        // the guard's else-branch would make `installRunLoopSource: false`
        // silently take an *extra* sample, which is what let an earlier draft
        // of the tests pass with the poll mechanism deleted.
        if installRunLoopSource, runLoopSource == nil {
            installSource()
        }
        refresh()
    }

    private func installSource() {
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
    }

    func setPopoverOpen(_ open: Bool) {
        guard isPopoverOpen != open else { return }
        isPopoverOpen = open
        // An opening popover must show a live value on its first frame, not
        // whatever the notification last delivered.
        if open { refresh() }
        reconcilePolling()
    }

    func setAssertionHeld(_ held: Bool) {
        guard isAssertionHeld != held else { return }
        isAssertionHeld = held
        reconcilePolling()
    }

    private func reconcilePolling() {
        let wanted = isPopoverOpen || isAssertionHeld
        if wanted {
            guard pollTask == nil else { return }
            let interval = pollInterval
            pollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self?.refresh()
                }
            }
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func refresh() {
        let snap = sampler()
        guard snap != subject.value else { return }
        subject.send(snap)
    }
}
