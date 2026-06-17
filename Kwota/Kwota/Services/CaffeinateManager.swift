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

/// Suppresses macOS App Nap while a keep-awake assertion is held. Without it the
/// menu-bar app gets napped once the user steps away and activity goes quiet,
/// which freezes the in-process release timers (`AwakeSupervisor`'s idle timer
/// and the manual `timeoutTask` below). The IOKit assertion lives in the kernel,
/// independent of the napped app, so it then lingers for hours until something
/// wakes the app — keeping the Mac awake long after the agent went idle.
/// Injectable so tests can verify begin/end pairing without touching `ProcessInfo`.
protocol AppNapSuppressing: AnyObject {
    func begin(reason: String) -> NSObjectProtocol
    func end(_ token: NSObjectProtocol)
}

final class ProcessInfoAppNapSuppressor: AppNapSuppressing {
    func begin(reason: String) -> NSObjectProtocol {
        // `.userInitiatedAllowingIdleSystemSleep` disables App Nap but, unlike
        // `.userInitiated`, leaves idle system sleep alone — sleep stays governed
        // solely by the IOKit assertions we configure per the user's flags, so
        // suppressing App Nap never silently keeps the Mac awake on its own.
        ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: reason)
    }

    func end(_ token: NSObjectProtocol) {
        ProcessInfo.processInfo.endActivity(token)
    }
}

@MainActor
final class CaffeinateManager: ObservableObject {
    @Published private(set) var isActive: Bool = false
    @Published private(set) var currentOptions: CaffeinateOptions?
    @Published private(set) var startedAt: Date?

    private let holder: SleepAssertionHolder
    private let appNap: AppNapSuppressing
    private var assertions: [SleepAssertion] = []
    private var appNapToken: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?

    init(holder: SleepAssertionHolder = IOKitSleepAssertionHolder(),
         appNap: AppNapSuppressing = ProcessInfoAppNapSuppressor()) {
        self.holder = holder
        self.appNap = appNap
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
        // Hold an App Nap-suppressing activity for as long as we're caffeinated,
        // so the in-process release timers (auto idle timer / manual timeout)
        // keep firing instead of being frozen while the user is away.
        appNapToken = appNap.begin(reason: "Kwota keep-awake")
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
        if let token = appNapToken {
            appNap.end(token)
            appNapToken = nil
        }
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
        if let appNapToken { appNap.end(appNapToken) }
    }
}
