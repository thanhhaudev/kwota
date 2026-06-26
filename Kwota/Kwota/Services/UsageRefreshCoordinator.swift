//
//  UsageRefreshCoordinator.swift
//  Kwota
//
//  Owns a single Timer that fires onTick at an adaptive interval:
//   - 120 seconds while the popover is open.
//   - 15 minutes while it is closed.
//
//  Each scheduled delay is jittered by ±jitterFraction (default 20%) so
//  the polling pattern is not a clean fixed-period signal that's trivial
//  to fingerprint. A server-driven `backoffUntil` floor (set from a 429
//  Retry-After header) overrides the base interval when present.
//
//  The timer is one-shot self-rescheduling rather than `repeats: true`
//  because each tick needs a freshly-randomized delay.
//

import Foundation

@MainActor
final class UsageRefreshCoordinator {
    private(set) var openInterval: TimeInterval
    private(set) var closedInterval: TimeInterval
    /// Fraction of `currentInterval` to randomize each scheduled delay by,
    /// symmetric around the base. 0.2 means delay ∈ [0.8·base, 1.2·base].
    /// Tests pass 0 to make scheduling deterministic.
    let jitterFraction: Double
    private let onTick: () -> Void
    private let now: () -> Date
    private let randomUnit: () -> Double

    private var timer: Timer?
    private var cadence: PopoverPollingCadence
    /// The interval the timer currently targets. Backed by `cadence`, which
    /// owns the open/closed switch logic shared with `AntigravityProcessWatcher`.
    var currentInterval: TimeInterval { cadence.currentInterval }

    /// Per-provider back-off floors. A 429 from one provider's API
    /// (Anthropic for Claude, OpenAI for Codex) does NOT gate other
    /// providers — Antigravity in particular talks to a local loopback
    /// server with no rate limit. Use `backoffUntil(for:)` to check a
    /// single provider; `backoffUntil` exposes the max across all
    /// providers and remains the scheduling input for the timer (so
    /// the timer doesn't fire while any provider is still waiting).
    private var backoffByProvider: [ProviderID: Date] = [:]

    /// Latest floor across all providers. Used by `nextDelay()` for
    /// timer scheduling and kept as a public read-only field for tests
    /// and diagnostic logging.
    var backoffUntil: Date? { backoffByProvider.values.max() }

    /// One-shot wake deadline for a known quota reset. This does not bypass
    /// per-provider back-off or the VM's burst throttle; it only makes the
    /// shared timer wake near `resetsAt` instead of waiting for the slower
    /// closed-popover cadence.
    private var resetWakeAt: Date?

    /// Per-provider floor lookup. nil = no active back-off for this
    /// provider. Callers gate fetches on this, not on the global
    /// `backoffUntil`, so a Claude 429 doesn't suppress an Antigravity
    /// refresh.
    func backoffUntil(for providerID: ProviderID) -> Date? {
        backoffByProvider[providerID]
    }

    init(
        openInterval: TimeInterval = 120,
        closedInterval: TimeInterval = 900,
        jitterFraction: Double = 0.2,
        now: @escaping () -> Date = Date.init,
        randomUnit: @escaping () -> Double = { Double.random(in: 0..<1) },
        onTick: @escaping () -> Void
    ) {
        self.openInterval = openInterval
        self.closedInterval = closedInterval
        self.jitterFraction = jitterFraction
        self.now = now
        self.randomUnit = randomUnit
        self.onTick = onTick
        self.cadence = PopoverPollingCadence(openInterval: openInterval, closedInterval: closedInterval)
    }

    func start() {
        onTick()
        scheduleNextTick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        // Invalidate the timer directly — stop() is @MainActor-isolated, but
        // Timer.invalidate is documented thread-safe so we can fire-and-forget
        // from nonisolated deinit.
        timer?.invalidate()
    }

    func popoverDidOpen() {
        if cadence.setOpen() { scheduleNextTick() }
    }

    func popoverDidClose() {
        if cadence.setClosed() { scheduleNextTick() }
    }

    /// Swap the open/closed cadence at runtime. Used when the user toggles
    /// "Battery Saver" in Settings — without this, the toggle would only
    /// take effect on the next app launch because the cadence is captured
    /// in `init`. Preserves the current popover open/closed state so a
    /// switch made while the popover is up stays on the fast cadence.
    func setIntervals(open: TimeInterval, closed: TimeInterval) {
        let wasOpen = cadence.currentInterval == cadence.openInterval
        self.openInterval = open
        self.closedInterval = closed
        var next = PopoverPollingCadence(openInterval: open, closedInterval: closed)
        if wasOpen { _ = next.setOpen() }
        self.cadence = next
        if timer != nil { scheduleNextTick() }
    }

    /// Records a server-suggested back-off (typically from a 429 response's
    /// `Retry-After` header) for `providerID`. Subsequent fetches for that
    /// provider are gated until `now() + retryAfterSeconds`; other
    /// providers are unaffected. The timer's next tick is also pushed
    /// out to honor whichever per-provider floor is latest.
    func applyRetryAfter(_ retryAfterSeconds: TimeInterval, for providerID: ProviderID) {
        let target = now().addingTimeInterval(max(0, retryAfterSeconds))
        // Take the latest of the existing per-provider floor and the new
        // one, so a longer pre-existing back-off isn't shortened by a
        // smaller hint.
        if let existing = backoffByProvider[providerID], existing > target {
            // keep existing
        } else {
            backoffByProvider[providerID] = target
        }
        scheduleNextTick()
    }

    /// Drops the back-off floor for `providerID`. Called when a fetch for
    /// that provider succeeds — a 200 proves the throttle has cleared, so
    /// waiting out the rest of a long Retry-After (the server can send
    /// 2000s+) would just delay the auto cadence for nothing. Other
    /// providers' floors are untouched.
    func clearBackoff(for providerID: ProviderID) {
        backoffByProvider[providerID] = nil
    }

    func scheduleResetWake(at date: Date?) {
        resetWakeAt = date
        if timer != nil { scheduleNextTick() }
    }

    /// Computes the next delay as `currentInterval` ± jitter.
    ///
    /// Note: the global `backoffUntil` (= max of per-provider floors) is
    /// intentionally NOT consulted here. The timer is shared across
    /// providers; gating it on the max would let one provider's 429 stop
    /// other providers' refreshes from being attempted. Per-provider
    /// gating lives in `MenuBarViewModel.canRefreshNow`, which inspects
    /// the active profile's own floor — ticks that find the active path
    /// throttled fall through to a cheap no-op, and ticks for an active
    /// provider with no floor proceed at the normal interval.
    ///
    /// Made internal-but-final-class so tests can verify jitter math.
    func nextDelay() -> TimeInterval {
        let baseInterval = currentInterval
        let delay: TimeInterval
        if jitterFraction <= 0 {
            delay = baseInterval
        } else {
            // map [0, 1) → [-jitterFraction, +jitterFraction)
            let signedJitter = (randomUnit() * 2 - 1) * jitterFraction
            delay = baseInterval * (1 + signedJitter)
        }
        let cadenceDelay = max(0, delay)
        guard let resetWakeAt else { return cadenceDelay }

        let resetDelay = max(0, resetWakeAt.timeIntervalSince(now()))
        if resetDelay <= 0 {
            self.resetWakeAt = nil
        }
        return min(cadenceDelay, resetDelay)
    }

    private func scheduleNextTick() {
        timer?.invalidate()
        let delay = nextDelay()
        let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.clearExpiredResetWake()
                self.onTick()
                self.scheduleNextTick()
            }
        }
        timer = t
    }

    private func clearExpiredResetWake() {
        if let resetWakeAt, resetWakeAt <= now() {
            self.resetWakeAt = nil
        }
    }
}
