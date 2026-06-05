//
//  CaffeinateManager.swift
//  Kwota
//
//  Holds IOKit power-management assertions to keep the Mac awake. Despite
//  the historical name, no /usr/bin/caffeinate child is spawned — the
//  assertions are held by Kwota's own process via `SleepAssertionHolder`,
//  and the kernel auto-releases them on any exit (crash, SIGKILL, reboot).
//  The class name is retained to minimize churn at the ~5 call sites; this
//  is intentional and called out in the design doc.
//

import Foundation
import AppKit
import Combine

@MainActor
final class CaffeinateManager: ObservableObject {
    @Published private(set) var isActive: Bool = false
    @Published private(set) var currentOptions: CaffeinateOptions?
    @Published private(set) var startedAt: Date?

    private let holder: SleepAssertionHolder
    private var assertions: [SleepAssertion] = []
    private var timeoutTask: Task<Void, Never>?

    init(holder: SleepAssertionHolder = IOKitSleepAssertionHolder()) {
        self.holder = holder
    }

    func enable(options: CaffeinateOptions = .default) throws {
        guard !isActive else { return }
        let name = "Kwota"
        if options.declareUserActivity {
            holder.declareUserActivity(name: name)
        }
        var acquired: [SleepAssertion] = []
        do {
            if options.preventDisplaySleep {
                acquired.append(try holder.acquire(.preventDisplaySleep, name: "\(name) (display)"))
            }
            if options.preventIdleSleep {
                acquired.append(try holder.acquire(.preventIdleSleep, name: "\(name) (idle)"))
            }
            if options.preventSystemSleep {
                acquired.append(try holder.acquire(.preventSystemSleep, name: "\(name) (system)"))
            }
        } catch {
            // Partial-acquire rollback: release whatever we got before propagating.
            for a in acquired { holder.release(a) }
            throw error
        }
        self.assertions = acquired
        isActive = true
        currentOptions = options
        startedAt = Date()
        AppLog.shared.log(
            "sleep assertions acquired: \(acquired.map(\.type.rawValue))",
            level: .info
        )
        if let t = options.timeoutSeconds, t > 0 {
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(t))
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                await MainActor.run { self?.disable() }
            }
        }
    }

    func disable() {
        timeoutTask?.cancel()
        timeoutTask = nil
        let toRelease = assertions
        assertions = []
        for a in toRelease { holder.release(a) }
        if isActive {
            AppLog.shared.log("sleep assertions released", level: .info)
        }
        isActive = false
        currentOptions = nil
        startedAt = nil
    }

    func toggle() throws {
        if isActive { disable() } else { try enable() }
    }

    deinit {
        timeoutTask?.cancel()
        // Release any held assertions so a deallocated manager doesn't leak
        // IOKit power assertions to the kernel. SleepAssertionHolder.release
        // carries no actor annotation, so it is safe from nonisolated deinit.
        // The @Published state mutations from disable() are skipped — no
        // observer can subscribe to a deallocated instance.
        for a in assertions { holder.release(a) }
    }
}
