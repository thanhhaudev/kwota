//
//  AwakeSupervisor.swift
//  Kwota
//

import AppKit
import Foundation
import Combine
import Observation

enum AwakeState: Equatable {
    case idle
    case autoActive(since: Date)
    case manualActive(since: Date, timeout: TimeInterval?)
    case batteryBlocked
}

enum AwakeBlockReason: Error, Equatable {
    case batteryBelowThreshold(current: Int, threshold: Int)
    case launchFailed
    case autoEnabled
}

@MainActor
@Observable
final class AwakeSupervisor {
    private(set) var state: AwakeState = .idle
    private(set) var lastJSONLActivity: Date?
    private(set) var lastActiveProvider: ProviderID?

    @ObservationIgnored private let caffeine: CaffeinateManager
    @ObservationIgnored private let activity: ActivitySource
    @ObservationIgnored private let battery: BatteryMonitoring
    @ObservationIgnored private let notifier: AwakeNotifying
    @ObservationIgnored private let configStore: AwakeConfigStore
    @ObservationIgnored private let idleWindowOverride: TimeInterval?
    @ObservationIgnored private let userInput: UserInputIdleProviding
    /// Cadence of the user-return poll while `.autoActive`. Injectable so
    /// tests run in milliseconds.
    @ObservationIgnored private let userReturnPollInterval: TimeInterval
    @ObservationIgnored private var userReturnPollTask: Task<Void, Never>?
    @ObservationIgnored private var bag = Set<AnyCancellable>()
    @ObservationIgnored private var idleTimerTask: Task<Void, Never>?
    /// Suppresses `onCaffeineActiveChanged` during the disable→enable swap in `forceStart`.
    @ObservationIgnored private var suppressCaffeineExitReaction = false
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    /// Injected so tests can use a private `NotificationCenter` and avoid
    /// firing fake sleep/wake notifications into the process-wide
    /// `NSWorkspace.shared.notificationCenter`, which other suites'
    /// AwakeSupervisor / CodexAccountWatcher / CLIAccountWatcher /
    /// MenuBarViewModel instances may be subscribed to under parallel runs.
    /// Marked `nonisolated(unsafe)` for the same reason as
    /// `wakeObserver` / `sleepObserver`: written once in `init`, read once
    /// in `deinit` from a non-isolated context.
    @ObservationIgnored nonisolated(unsafe) private let notificationCenter: NotificationCenter
    @ObservationIgnored private let onWillSleep: ((Date, AwakeState) -> Void)?
    @ObservationIgnored private let onDidWakeFromSleep: ((Date, AwakeState) -> Void)?
    @ObservationIgnored private let clock: () -> Date

    init(
        caffeine: CaffeinateManager,
        activity: ActivitySource,
        battery: BatteryMonitoring,
        notifier: AwakeNotifying,
        configStore: AwakeConfigStore,
        idleWindowOverride: TimeInterval? = nil,
        userInput: UserInputIdleProviding = SystemUserInputMonitor(),
        userReturnPollInterval: TimeInterval = 2.0,
        clock: @escaping () -> Date = { Date() },
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        onWillSleep: ((Date, AwakeState) -> Void)? = nil,
        onDidWakeFromSleep: ((Date, AwakeState) -> Void)? = nil
    ) {
        self.caffeine = caffeine
        self.activity = activity
        self.battery = battery
        self.notifier = notifier
        self.configStore = configStore
        self.idleWindowOverride = idleWindowOverride
        self.userInput = userInput
        self.userReturnPollInterval = userReturnPollInterval
        self.clock = clock
        self.notificationCenter = notificationCenter
        self.onWillSleep = onWillSleep
        self.onDidWakeFromSleep = onDidWakeFromSleep
        battery.start()
        activity.activityPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.onActivity(at: event.date, provider: event.provider)
            }
            .store(in: &bag)
        caffeine.$isActive
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                self?.onCaffeineActiveChanged(active)
            }
            .store(in: &bag)
        battery.readingPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] reading in
                self?.onBatteryChange(reading)
            }
            .store(in: &bag)
        wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onSystemWake() }
        }
        sleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onSystemWillSleep() }
        }
    }

    deinit {
        idleTimerTask?.cancel()
        userReturnPollTask?.cancel()
        let center = self.notificationCenter
        if let wakeObserver  { center.removeObserver(wakeObserver) }
        if let sleepObserver { center.removeObserver(sleepObserver) }
    }

    var config: AwakeConfig { configStore.config }

    /// Read-only mirror of the current battery percentage, for status UI.
    /// Nil on Macs with no battery hardware (desktops).
    var currentBatteryPercent: Int? { battery.reading.percent }

    private var effectiveIdleWindow: TimeInterval {
        idleWindowOverride ?? config.idleWindow.seconds
    }

    private func onActivity(at date: Date, provider: ProviderID) {
        lastJSONLActivity = date
        guard config.autoEnabled else { return }
        if case .batteryBlocked = state { return }
        if case .manualActive = state { return }   // manual outranks auto

        if case .idle = state {
            // User-presence gate: while the user is actively at the Mac,
            // macOS can't idle-sleep, so raising the assertion is pointless
            // noise. Only caffeinate once they've been away long enough.
            // Manual mode (forceStart) is intentionally not gated.
            //
            // Accepted race: re-engagement is pulse-driven, so with an
            // aggressively short system-sleep timer (pmset sleep 1-3) and an
            // agent that goes silent across the moment the gate opens, the
            // Mac can sleep before the next pulse re-arms us. Realistic sleep
            // timers (>= 5 min) and active agents (pulses every few seconds)
            // make this window irrelevant in practice.
            if let gateSeconds = config.userIdleGate.seconds,
               userInput.secondsSinceLastInput() < gateSeconds {
                return
            }
            do {
                try caffeine.enable(options: config.flags)
                state = .autoActive(since: date)
                startUserReturnPoll()
            } catch {
                AppLog.shared.log("auto-awake enable failed: \(error)", level: .error)
                return
            }
        }
        lastActiveProvider = provider
        rescheduleIdleTimer()
    }

    private func rescheduleIdleTimer() {
        idleTimerTask?.cancel()
        let window = effectiveIdleWindow
        idleTimerTask = Task { @MainActor [weak self] in
            let nanos = UInt64((window * 1_000_000_000).rounded())
            do {
                try await Task.sleep(nanoseconds: nanos)
            } catch {
                return   // cancelled — don't fire
            }
            self?.onIdleTimerFired()
        }
    }

    private func onIdleTimerFired() {
        guard case .autoActive = state else { return }
        state = .idle
        lastActiveProvider = nil
        caffeine.disable()
        userReturnPollTask?.cancel()
        userReturnPollTask = nil
        let minutes = Int(config.idleWindow.seconds / 60)
        notifier.notifyStopped(.agentIdle(minutes: minutes))
    }

    /// While `.autoActive`, watch for the user coming back to the Mac and
    /// release the assertion the moment they do — the OS-managed idle timer
    /// takes over. The task self-terminates as soon as the state leaves
    /// `.autoActive`, so missed cancels at exotic exit paths only cost one
    /// extra tick. No-op when the gate is `.off`.
    private func startUserReturnPoll() {
        userReturnPollTask?.cancel()
        guard config.userIdleGate.seconds != nil else { return }
        let interval = userReturnPollInterval
        userReturnPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return   // cancelled
                }
                // Re-check after the sleep: a cancel that landed mid-sleep
                // (e.g. the gate was just switched off) must not fire one
                // last release from the already-queued tick.
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard case .autoActive = self.state else { return }
                // "Returned" = an input event landed since (roughly) the
                // last tick. interval + 1 absorbs Task.sleep jitter.
                if self.userInput.secondsSinceLastInput() < interval + 1 {
                    self.stopAutoForUserReturn()
                    return
                }
            }
        }
    }

    /// User came back mid-session: drop to `.idle` and release. Deliberately
    /// no notification — the user is sitting at the Mac and caused this stop;
    /// pinging them for touching the mouse would be spam. The next agent
    /// pulse re-engages once they've been away ≥ the gate threshold again.
    private func stopAutoForUserReturn() {
        guard case .autoActive = state else { return }
        state = .idle
        lastActiveProvider = nil
        suppressCaffeineExitReaction = true
        caffeine.disable()
        idleTimerTask?.cancel()
        idleTimerTask = nil
    }

    @discardableResult
    func forceStart(options: CaffeinateOptions, timeout: TimeInterval?) -> Result<Void, AwakeBlockReason> {
        // Auto and manual are alternative triggers, never concurrent. The
        // popover hides the force button when auto is on, but this guard
        // is the source of truth.
        if config.autoEnabled {
            return .failure(.autoEnabled)
        }
        if case .batteryBlocked = state {
            let cur = battery.reading.percent ?? 0
            let thresh = config.batteryThreshold.percent ?? 0
            return .failure(.batteryBelowThreshold(current: cur, threshold: thresh))
        }
        if caffeine.isActive {
            state = .idle
            suppressCaffeineExitReaction = true
            caffeine.disable()
        } else {
            state = .idle
        }
        var opts = options
        if let timeout {
            opts.timeoutSeconds = Int(timeout)
        }
        do {
            try caffeine.enable(options: opts)
            state = .manualActive(since: Date(), timeout: timeout)
            idleTimerTask?.cancel()
            idleTimerTask = nil
            return .success(())
        } catch {
            AppLog.shared.log("force-awake enable failed: \(error)", level: .error)
            // No restore: any prior active state had its process killed by
            // disable() above. Stay in .idle; auto path re-engages on the
            // next JSONL append.
            return .failure(.launchFailed)
        }
    }

    func forceStop() {
        guard case .manualActive = state else { return }
        state = .idle
        caffeine.disable()
        // No notification for user-initiated stops.
    }

    // MARK: Config mutations

    func setAutoEnabled(_ enabled: Bool) {
        configStore.mutate { $0.autoEnabled = enabled }
        switch (enabled, state) {
        case (false, .autoActive):
            state = .idle
            lastActiveProvider = nil
            suppressCaffeineExitReaction = true
            caffeine.disable()
            idleTimerTask?.cancel()
            idleTimerTask = nil
            userReturnPollTask?.cancel()
            userReturnPollTask = nil
        case (true, .manualActive):
            // User flipped auto back on while a manual session was running.
            // Manual outranks auto today, but in the alternative-modes model
            // they can never coexist — stop manual immediately so the auto
            // path can re-engage on the next JSONL append.
            state = .idle
            lastActiveProvider = nil
            suppressCaffeineExitReaction = true
            caffeine.disable()
        default:
            break
        }
    }

    func updateFlags(_ flags: CaffeinateOptions) {
        configStore.mutate { $0.flags = flags }
        if case .autoActive(let since) = state {
            suppressCaffeineExitReaction = true
            caffeine.disable()
            do {
                try caffeine.enable(options: flags)
                state = .autoActive(since: since)
            } catch {
                state = .idle
                lastActiveProvider = nil
                userReturnPollTask?.cancel()
                userReturnPollTask = nil
                AppLog.shared.log("flag-restart failed: \(error)", level: .error)
                notifier.notifyStopped(.unexpectedExit)
            }
        }
    }

    func updateIdleWindow(_ window: IdleWindow) {
        configStore.mutate { $0.idleWindow = window }
        if case .autoActive = state {
            rescheduleIdleTimer()
        }
    }

    func updateUserIdleGate(_ gate: UserIdleGate) {
        configStore.mutate { $0.userIdleGate = gate }
        if case .autoActive = state {
            // Re-arm (or stop) the return-watch under the new setting.
            startUserReturnPoll()
        }
    }

    func updateBatteryThreshold(_ threshold: BatteryThreshold) {
        configStore.mutate { $0.batteryThreshold = threshold }
        onBatteryChange(battery.reading)   // re-evaluate immediately
    }

    func updateForceTimeout(_ choice: TimeoutChoice) {
        configStore.mutate { $0.forceTimeout = choice }
    }

    // MARK: System sleep / wake

    /// Fires just before the Mac enters sleep. Caffeinate-i survives sleep
    /// (the process is suspended, not killed), so `state` stays
    /// `.autoActive`/`.manualActive` straight through. But the *Mac* was
    /// awake only until this moment — the consumer callback closes the
    /// open `AwakeSession` here so the chart's tint doesn't bleed across
    /// the sleep interval.
    private func onSystemWillSleep() {
        onWillSleep?(clock(), state)
    }

    private func onSystemWake() {
        // After resume, re-evaluate battery first — that may transition us
        // out of an active state (low battery) — and only then signal the
        // wake callback with the post-evaluation state.
        onBatteryChange(battery.reading)
        if case .autoActive = state {
            rescheduleIdleTimer()
        }
        onDidWakeFromSleep?(clock(), state)
    }

    /// Reacts to `caffeine.$isActive` flipping to `false`. This happens for
    /// three reasons: (a) we called `disable()` ourselves; (b) caffeinate's
    /// own `-t` timer fired and the child exited; (c) the child was killed
    /// externally. For (a), the supervisor has already transitioned away
    /// from any active state — the switch falls through. For (b) and (c)
    /// in `.manualActive` or `.autoActive`, we transition to `.idle` and
    /// surface a notification.
    private func onCaffeineActiveChanged(_ active: Bool) {
        guard !active else { return }
        if suppressCaffeineExitReaction {
            suppressCaffeineExitReaction = false
            return
        }
        switch state {
        case .manualActive:
            state = .idle
            notifier.notifyStopped(.forceTimeoutElapsed)
            idleTimerTask?.cancel()
            idleTimerTask = nil
        case .autoActive:
            state = .idle
            lastActiveProvider = nil
            notifier.notifyStopped(.unexpectedExit)
            idleTimerTask?.cancel()
            idleTimerTask = nil
            userReturnPollTask?.cancel()
            userReturnPollTask = nil
        case .idle, .batteryBlocked:
            break
        }
    }

    private func onBatteryChange(_ reading: BatteryReading) {
        guard let threshold = config.batteryThreshold.percent else {
            // .off — clear blocked state if we got there earlier.
            if case .batteryBlocked = state { state = .idle }
            return
        }
        let belowThreshold = reading.isOnBattery
            && (reading.percent ?? Int.max) < threshold

        if belowThreshold {
            switch state {
            case .autoActive, .manualActive:
                // State-first to avoid double-notification from the
                // caffeine.$isActive Combine path (see T10 race notes).
                state = .batteryBlocked
                lastActiveProvider = nil
                suppressCaffeineExitReaction = true
                caffeine.disable()
                idleTimerTask?.cancel()
                idleTimerTask = nil
                userReturnPollTask?.cancel()
                userReturnPollTask = nil
                notifier.notifyStopped(.batteryBelowThreshold(
                    current: reading.percent ?? 0,
                    threshold: threshold
                ))
            case .idle, .batteryBlocked:
                state = .batteryBlocked
            }
        } else {
            if case .batteryBlocked = state {
                state = .idle
                // Auto re-engages on next JSONL append.
            }
        }
    }
}
