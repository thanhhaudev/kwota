//
//  AwakeWatchdog.swift
//  Kwota
//
//  Releases Kwota's keep-awake assertion without the main actor.
//
//  Every existing release path — the idle timer, the user-return poll, the
//  battery notification sink, the manual timeout — runs on `@MainActor`, while
//  the IOKit assertion lives in the kernel and outlives any app-side stall.
//  F-003 is what that asymmetry costs: eight hours of assertion, a battery
//  drained to 1%, and a forced Low Power Sleep. This type is the one release
//  path with no main-thread dependency anywhere in it.
//

import Foundation
import Combine

nonisolated protocol AwakeWatchdogging: AnyObject, Sendable {
    /// Takes ownership of `assertions` and starts ticking. `releaseAfter` is
    /// the app's own intended release window — the idle window for auto, the
    /// timeout for manual — and the watchdog adds `deadlineGrace` itself so
    /// that constant is defined in exactly one place. Pass nil for
    /// manual-without-timeout: that session is governed by the battery rule only.
    func arm(assertions: [SleepAssertion], mode: WatchdogMode, releaseAfter: TimeInterval?)

    /// Pushes the deadline out to `releaseAfter + grace` from now. No-op when
    /// not armed, or when the armed session has no deadline rule.
    func bumpDeadline(releaseAfter: TimeInterval)

    /// Config push. Valid whether or not armed.
    func setBatteryThreshold(_ percent: Int?)

    /// Liveness ping from the main actor. Diagnostic only — never a trigger.
    func mainHeartbeat()

    /// Seconds since the last tick, or nil when never ticked. The main actor
    /// reads this to notice a watchdog that has silently stopped.
    func lastTickAgeSeconds() -> TimeInterval?

    /// Hands ownership back and returns exactly the assertions the caller must
    /// now release — empty when the watchdog already released them all.
    ///
    /// An array rather than a Bool on purpose. A Bool must mean either "was
    /// still armed" or "had not fired", and the partial-failure path makes those
    /// diverge: after a firing where some releases failed, the watchdog is still
    /// armed *and* has already fired, and the kernel still holds those
    /// assertions. Either Bool answer loses information, and the losing answer
    /// strands a live assertion with no owner — F-003 all over again.
    func disarm() -> [SleepAssertion]

    /// Everything the watchdog observes. Sent from its own queue; subscribers
    /// hop to the main actor themselves.
    var events: AnyPublisher<WatchdogEvent, Never> { get }
}

nonisolated final class AwakeWatchdog: AwakeWatchdogging, @unchecked Sendable {

    static let defaultDeadlineGrace: TimeInterval = 120
    static let defaultBatteryGrace: TimeInterval = 120
    static let stallThreshold: TimeInterval = 180
    static let watchdogSilentThreshold: TimeInterval = 90
    static let nudgeAfter: TimeInterval = 2 * 3600
    /// How long `arm()`/`disarm()` will wait for an in-flight `tick()` release
    /// to resolve before giving up and proceeding anyway (see
    /// `waitForInFlightRelease`). A real `IOPMAssertionRelease` call is local
    /// mach IPC and normally resolves in well under a millisecond, so this is
    /// generous slack for a slow-but-healthy release, not a budget anyone
    /// should expect to actually spend — while still being short enough that
    /// a genuinely wedged `powerd` can't freeze whatever main-actor recovery
    /// path called in for anywhere near as long as F-003's multi-hour stalls.
    static let defaultReleaseWaitTimeout: TimeInterval = 3

    /// Instance properties, not constants, purely so tests can drive a real
    /// `DispatchSourceTimer` without waiting out a two-minute grace. Production
    /// always takes the defaults above.
    private let deadlineGrace: TimeInterval
    private let batteryGrace: TimeInterval
    private let releaseWaitTimeout: TimeInterval

    private struct Armed {
        var assertions: [SleepAssertion]
        var deadlineUptime: UInt64?
        var mode: WatchdogMode
        var startedAtWall: Date
        var startedAtUptime: UInt64
        var lastMainHeartbeatUptime: UInt64
        var stallLatched: Bool
        var nudgeSent: Bool
        /// Set once the firing has been recorded and published, so retries of
        /// a failed `IOPMAssertionRelease` never duplicate either.
        var firingReported: Bool
    }

    /// `NSCondition` rather than `NSLock`: `arm()`/`disarm()` need to wait for
    /// an in-flight `tick()` release to finish (see `releasingEpoch` below)
    /// without polling, and `NSCondition` gives that for free while still
    /// supporting plain `lock()`/`unlock()` everywhere else in this file.
    private let lock = NSCondition()
    private var armed: Armed?
    /// Bumped on every `arm()`/`disarm()`. `tick()` snapshots this alongside
    /// `armed` before doing unlocked IO, then checks it again before writing
    /// its result back — if it changed in between, the session `tick()` was
    /// releasing has already ended or been replaced, and committing stale
    /// results would resurrect or clobber the wrong one.
    private var armEpoch: UInt64 = 0
    /// Set to the epoch of the session `tick()` is currently releasing,
    /// exactly for the unlocked window between its decision and commit
    /// passes; nil the rest of the time — including across the earlier,
    /// unlocked battery sample, which releases nothing. `arm()`/`disarm()` wait on this
    /// rather than proceeding, so neither ever calls `releaser()` on an
    /// assertion ID `tick()` is concurrently releasing — the double-release
    /// race a Bool-only lock-scope fix would otherwise still allow.
    private var releasingEpoch: UInt64?
    private var batteryThreshold: Int?
    private var batteryBelowSinceUptime: UInt64?
    private var lastTickUptime: UInt64?

    private let tickInterval: TimeInterval
    private let uptime: @Sendable () -> UInt64
    private let wallClock: @Sendable () -> Date
    private let releaser: @Sendable (SleepAssertion) -> Int32
    private let sampler: @Sendable () -> BatteryReading
    private let evidence: any WatchdogEvidenceWriting
    private let subject = PassthroughSubject<WatchdogEvent, Never>()

    init(
        tickInterval: TimeInterval = 30,
        deadlineGrace: TimeInterval = AwakeWatchdog.defaultDeadlineGrace,
        batteryGrace: TimeInterval = AwakeWatchdog.defaultBatteryGrace,
        releaseWaitTimeout: TimeInterval = AwakeWatchdog.defaultReleaseWaitTimeout,
        uptime: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        wallClock: @escaping @Sendable () -> Date = Date.init,
        releaser: @escaping @Sendable (SleepAssertion) -> Int32 = { IOKitSleepAssertionHolder.releaseRaw($0) },
        sampler: @escaping @Sendable () -> BatteryReading = PowerSourceSampler.snapshot,
        evidence: any WatchdogEvidenceWriting = NoopWatchdogEvidenceWriter(),
        autoStartTimer: Bool = true
    ) {
        self.deadlineGrace = deadlineGrace
        self.batteryGrace = batteryGrace
        self.releaseWaitTimeout = releaseWaitTimeout
        self.tickInterval = tickInterval
        self.uptime = uptime
        self.wallClock = wallClock
        self.releaser = releaser
        self.sampler = sampler
        self.evidence = evidence
        // Timer wiring lands in Task 7; `autoStartTimer` is threaded through
        // now so call sites and tests do not change shape later.
        _ = autoStartTimer
    }

    var events: AnyPublisher<WatchdogEvent, Never> { subject.eraseToAnyPublisher() }

    // MARK: Arming

    /// Waits for an in-flight `tick()` release of the currently-armed session
    /// to resolve, bounded by `releaseWaitTimeout`. Must be called with `lock`
    /// already held. Returns `true` if the deadline was reached before the
    /// release resolved (i.e. `tick()` — most plausibly `releaser()` itself —
    /// is still stuck), `false` if there was nothing to wait for or the wait
    /// resolved normally.
    ///
    /// Unbounded here would mean a wedged `IOPMAssertionRelease` inside
    /// `tick()` freezes whichever synchronous, main-actor-called method
    /// (`arm()`/`disarm()`) happens to race it — the exact failure class this
    /// type exists to prevent, arriving via its own concurrency fix instead of
    /// via the app's original release paths.
    private func waitForInFlightRelease() -> Bool {
        guard armed != nil, releasingEpoch == armEpoch else { return false }
        let deadline = Date().addingTimeInterval(releaseWaitTimeout)
        while armed != nil && releasingEpoch == armEpoch {
            if !lock.wait(until: deadline) {
                return true
            }
        }
        return false
    }

    func arm(assertions: [SleepAssertion], mode: WatchdogMode, releaseAfter: TimeInterval?) {
        let now = uptime()
        lock.lock()
        // If `tick()` is mid-release for whatever is currently armed, wait for
        // it to finish before taking over. Without this, the stale-cleanup
        // loop below could call `releaser()` on the exact same assertion IDs
        // `tick()` is independently releasing right now — a double release of
        // real IOPMAssertionRelease calls, not just a bookkeeping race.
        if waitForInFlightRelease() {
            // The previous session's release never resolved within our
            // budget — most plausibly a wedged `powerd`. Proceed anyway
            // rather than hang this call (and whatever main-actor path
            // invoked it) indefinitely: verified empirically, a duplicate
            // `IOPMAssertionRelease` on an already-released or
            // concurrently-releasing valid ID returns `kIOReturnBadArgument`
            // to whichever caller loses the race, not a crash — so racing the
            // wedged call is the safer failure mode compared to freezing the
            // caller forever. The stale-cleanup release below runs off this
            // thread precisely because it is a *second* call into the same
            // mechanism we just proved unresponsive.
            AppLog.shared.log(
                "AwakeWatchdog.arm timed out waiting for the previous session's in-flight release; proceeding anyway",
                level: .error
            )
        }
        let stale = armed
        armed = Armed(
            assertions: assertions,
            deadlineUptime: releaseAfter.map { now &+ nanos($0 + deadlineGrace) },
            mode: mode,
            startedAtWall: wallClock(),
            startedAtUptime: now,
            lastMainHeartbeatUptime: now,
            stallLatched: false,
            nudgeSent: false,
            firingReported: false
        )
        armEpoch &+= 1
        batteryBelowSinceUptime = nil
        lock.unlock()

        // IO (log + release) happens unlocked: `stale` is already detached
        // from `armed`, so there is nothing left for another thread to race
        // against here, and a wedged `releaser` must not be able to block a
        // concurrent `disarm()`/`mainHeartbeat()` behind this lock.
        if let stale {
            // Reaching this is a caller lifecycle bug, but overwriting `armed`
            // while it still holds unreleased assertions leaks them to nobody.
            AppLog.shared.log("AwakeWatchdog.arm called while already armed", level: .warn)
            // Fire-and-forget on a background queue, never on the calling
            // thread. `arm()` is synchronous and main-actor-called, and the
            // wait above is bounded precisely so this method can't freeze;
            // running the cleanup releases here would hand that freeze right
            // back one statement later. The whole reason the wait can time out
            // is that the release mechanism may be genuinely unresponsive, and
            // a fresh call into an unresponsive `powerd` blocks on mach IPC
            // rather than failing fast — so every `releaser()` call this path
            // makes has to be off-thread for `arm()` to stay bounded by
            // `releaseWaitTimeout`. Nothing waits on the outcome: `stale` is
            // detached from `armed`, so no other code path tracks these IDs,
            // and the only thing lost by not waiting is a status code that had
            // no reader anyway. Raw GCD rather than `Task.detached` on purpose —
            // this target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`,
            // so a detached task body would run right back on the main actor.
            let release = releaser
            let orphaned = stale.assertions
            DispatchQueue.global().async {
                for assertion in orphaned { _ = release(assertion) }
            }
        }
    }

    func bumpDeadline(releaseAfter: TimeInterval) {
        let now = uptime()
        lock.lock()
        defer { lock.unlock() }
        // Once a firing has been reported, the deadline has already done its
        // job and a straggler assertion may still be pending retry. Letting
        // ordinary main-actor activity (agent replies, keystrokes) push the
        // deadline back out here would silence that retry indefinitely —
        // the exact multi-hour stuck assertion this watchdog exists to catch.
        guard var current = armed, current.deadlineUptime != nil, !current.firingReported else { return }
        current.deadlineUptime = now &+ nanos(releaseAfter + deadlineGrace)
        armed = current
    }

    func setBatteryThreshold(_ percent: Int?) {
        lock.lock()
        batteryThreshold = percent
        if percent == nil { batteryBelowSinceUptime = nil }
        lock.unlock()
    }

    func mainHeartbeat() {
        let now = uptime()
        lock.lock()
        defer { lock.unlock() }
        guard var current = armed else { return }
        current.lastMainHeartbeatUptime = now
        current.stallLatched = false
        armed = current
    }

    func lastTickAgeSeconds() -> TimeInterval? {
        let now = uptime()
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastTickUptime else { return nil }
        return seconds(now &- last)
    }

    func disarm() -> [SleepAssertion] {
        lock.lock()
        defer { lock.unlock() }
        // If `tick()` is mid-release for the currently armed session, the
        // assertions sitting in `armed` right now are the exact ones its
        // unlocked release loop is already calling `releaser()` on. Racing
        // ahead and handing them back here too would mean two independent
        // `IOPMAssertionRelease` calls for the same ID — wait for that release
        // to finish and land its outcome (success clears `armed`; failure
        // leaves the true straggler) before answering.
        if waitForInFlightRelease() {
            // The in-flight release never resolved within our budget. Hand
            // the assertions back anyway rather than returning empty: if this
            // call returned empty here, the caller believes the session ended
            // cleanly and stops tracking it, and if the wedged release truly
            // never returns, that assertion is now orphaned with no owner at
            // all — the exact F-003 failure this type exists to close.
            // Handing it back risks, at worst, a second concurrent
            // `IOPMAssertionRelease` on the same ID once the wedged call
            // eventually resolves — empirically confirmed to return
            // `kIOReturnBadArgument` to the loser, not a crash — which is a
            // strictly safer outcome than a silent, permanent orphan.
            AppLog.shared.log(
                "AwakeWatchdog.disarm timed out waiting for an in-flight release; handing back assertions that may still be mid-release rather than risk orphaning them",
                level: .error
            )
        }
        // Whatever is still in `armed` is still held by the kernel — either we
        // never fired, or we fired and some releases failed. Either way the
        // caller must release it; dropping it here is how an assertion ends up
        // with no owner at all.
        let stillHeld = armed?.assertions ?? []
        armed = nil
        armEpoch &+= 1
        batteryBelowSinceUptime = nil
        return stillHeld
    }

    // MARK: Tick

    /// Internal so tests drive it directly rather than waiting on a real timer.
    ///
    /// Structured so `lock` is never held across `releaser()`, `sampler()`, or
    /// `AppLog` calls. Those can block on `powerd`/IOKit or on the log's own
    /// queue; a main actor that calls `mainHeartbeat()`/`lastTickAgeSeconds()`/
    /// `bumpDeadline()`/`setBatteryThreshold()` synchronously would otherwise
    /// queue up behind whichever thread is doing that IO, turning the one
    /// release path with no main-thread dependency into a new way to stall the
    /// main thread — the exact failure class this type exists to catch.
    /// `arm()`/`disarm()` are the two calls that *do* need to coordinate with
    /// the release window (see `releasingEpoch`), because they touch the very
    /// assertions this method is releasing.
    ///
    /// The passes, in order:
    ///
    /// 1. locked, no IO — snapshot, and decide whether Pass 2's sample is
    ///    worth taking.
    /// 2. unlocked — take the battery sample, when either the battery rule or
    ///    the untimed-on-battery nudge needs one.
    /// 3. locked, no IO — evaluate both rules against that sample, advance the
    ///    below-threshold window, and then either claim the release window or,
    ///    on a tick that releases nothing, record the two notify-only
    ///    observations (stall, nudge) and return.
    /// 4. unlocked — the releases, the log, and any late sample.
    /// 5. locked, no IO — commit the outcome.
    ///
    /// The battery rule is why this has five passes rather than three: unlike
    /// the deadline rule (pure arithmetic on already-snapshotted state), its
    /// condition needs a live IOKit sample, so the decision cannot be made in
    /// one locked pass without holding `lock` across that sample.
    ///
    /// Pass 1 deliberately does *not* bail out for a session that is armed,
    /// even though an earlier version did. Stall observation has to run on the
    /// ticks where nothing is anywhere near firing, because a self-recovering
    /// freeze happens on exactly those ticks and leaves no other trace. What
    /// used to be an early return survives as `needsSample`, so the IOKit cost
    /// the bail existed to avoid is still avoided; all an idle session pays now
    /// is one more uncontended lock acquisition and some arithmetic.
    func tick() {
        let now = uptime()

        // Pass 1: snapshot under lock. No IO here, so this is always fast.
        lock.lock()
        lastTickUptime = now
        guard let snapshot = armed else { lock.unlock(); return }
        let epoch = armEpoch
        let threshold = batteryThreshold
        // Cheap pre-check purely to decide whether Pass 2's sample is worth
        // taking; it no longer decides whether the rest of the tick runs at all.
        // A configured threshold means this tick has to sample even when nothing
        // is close to firing, because the below-threshold window has to start
        // counting (and stop counting) on the tick the reading crosses, not on
        // the tick something finally fires.
        //
        // The nudge is the other reason to sample, and it wants a reading in
        // precisely the case the threshold clause skips: no deadline rule and no
        // threshold, so nothing else in this method would ever look at the power
        // source. Gated on `nudgeSent` as well as on elapsed time, so a session
        // that has already been nudged stops paying for the query for the rest
        // of its life — an untimed session can easily run all day.
        //
        // Everything else this tick might do — both rules, the failed-release
        // retry, and stall observation — is pure arithmetic on state the lock
        // already protects, so Pass 3 can decide all of it without sampling.
        let nudgeMayBeDue = snapshot.deadlineUptime == nil
            && threshold == nil
            && !snapshot.nudgeSent
            && seconds(now &- snapshot.startedAtUptime) >= Self.nudgeAfter
        let needsSample = threshold != nil || nudgeMayBeDue
        lock.unlock()

        // Pass 2: unlocked sample. `sampler()` is an IOKit power-source query,
        // so it belongs outside the lock for the same reason `releaser()` does.
        let reading: BatteryReading? = needsSample ? sampler() : nil

        // Pass 3: back under the lock to decide, with no IO of any kind. Pass 1's
        // snapshot is deliberately not trusted here — the unlocked sample above
        // is a window in which `arm()`/`disarm()`/`bumpDeadline()`/
        // `mainHeartbeat()` may all have run — so the session is re-read and the
        // deadline re-evaluated against whatever is armed *now*.
        lock.lock()
        guard armEpoch == epoch, var current = armed else { lock.unlock(); return }

        // Battery first: it is the rule tied to real-world harm and produces the
        // more actionable message when both trip on the same tick.
        var batteryLapsed = false
        // `batteryThreshold == threshold` is the same guard for config that
        // `armEpoch == epoch` is for the session: `setBatteryThreshold(nil)`
        // clears `batteryBelowSinceUptime`, and writing a window start back on
        // top of that clear would leave a stale start behind a disabled
        // threshold, ready to fire instantly whenever it was re-enabled. A
        // value that changed and changed back is treated as unchanged on
        // purpose — the sample was taken against that same number, and the only
        // cost is a window that restarts slightly late, which delays a firing
        // rather than causing an early one.
        if let threshold, let sample = reading, batteryThreshold == threshold {
            let below = sample.isOnBattery && (sample.percent ?? Int.max) < threshold
            if below {
                if let since = batteryBelowSinceUptime {
                    batteryLapsed = seconds(now &- since) > batteryGrace
                } else {
                    // First tick below the line only starts the clock. The main
                    // actor gets the full grace to notice and stop gracefully
                    // first; this is a backstop, not a competitor.
                    batteryBelowSinceUptime = now
                }
            } else {
                batteryBelowSinceUptime = nil
            }
        }

        let deadlineLapsed = current.deadlineUptime.map { now > $0 } ?? false
        // `firingReported` keeps a failed release retrying even when neither
        // rule currently holds. The deadline rule never needed this: `now >
        // deadlineUptime` is monotonic and `bumpDeadline()` refuses to move it
        // after a firing, so its condition stays true forever and every
        // subsequent tick naturally retried. The battery rule is the opposite —
        // it un-trips the instant the sample recovers, AC is plugged in, or the
        // threshold is turned off, and plugging in is the single most likely
        // thing to happen right after a low-battery release fires. Without this
        // clause, a battery firing whose `releaser()` call failed on an untimed
        // manual session (battery rule only, so no deadline to fall back on)
        // would abandon its own straggler here on the very next tick, leaving a
        // live kernel assertion nobody retries until `disarm()` — F-003 again,
        // reached through the rule meant to prevent it.
        if !batteryLapsed && !deadlineLapsed && !current.firingReported {
            // Nothing to release on this tick: both rules are quiet and no
            // straggler is pending. That makes this the only tick shape the two
            // notify-only observations belong on, and it is why they live here
            // rather than above the release decision. A `.stallObserved`
            // alongside a `.fired` would be pure duplication — the firing record
            // already carries `mainStallSeconds` — and it would also put a
            // second event ahead of `.fired`, which every earlier test that
            // reads the first received event or counts total evidence records
            // depends on not happening. A lapsed deadline is a stall by
            // construction, so that collision would be the common case rather
            // than a rare one. Reaching this branch is the proof that no firing
            // happens this tick; no separate flag is needed to say so.
            //
            // The retry-only tick (`firingReported`, release still pending) is
            // excluded here too, and that is right rather than merely
            // convenient: a session with a straggler is one the watchdog is
            // actively trying to release, so neither "your main actor is quiet"
            // nor "you might want to end this session" is news the user can act
            // on, and both would land on top of the firing record that already
            // says something louder.
            var notices: [WatchdogEvent] = []

            // Untimed manual on battery with no threshold configured is the only
            // remaining path to a drained machine. Nudge rather than release: an
            // untimed session is a deliberate choice, and the complaint behind
            // F-003 was that the Mac stayed awake *unexplained*, not that it
            // stayed awake at all.
            //
            // The reading is Pass 2's, never a fresh one — `sampler()` is IOKit
            // and this is a locked pass. It is also never actually missing when
            // the rest of these conditions hold. Pass 1 evaluated the same
            // eligibility against the same `now`, and within one `armEpoch` none
            // of these inputs can turn *on* mid-tick: a nil `deadlineUptime`
            // stays nil because `bumpDeadline` refuses a session without a
            // deadline rule, `startedAtUptime` is immutable, and `nudgeSent` is
            // written by nothing but this branch. The one input that can move,
            // `batteryThreshold`, can only make the nudge newly eligible by
            // being *cleared* — and a threshold that was set at Pass 1 means
            // Pass 1 sampled for the battery rule and left a reading here
            // anyway. So the `let sample` is unreachable as a bail-out, and
            // harmless if it ever were reached: `nudgeSent` stays false, so the
            // next tick's Pass 1 asks for the sample and nudges then.
            let heldSoFar = seconds(now &- current.startedAtUptime)
            if let sample = reading,
               current.deadlineUptime == nil,
               batteryThreshold == nil,
               !current.nudgeSent,
               heldSoFar >= Self.nudgeAfter,
               sample.isOnBattery {
                current.nudgeSent = true
                // `hours` is the *elapsed* session length, floored, not
                // `nudgeAfter` restated. Only `nudgeAfter` decides *whether* to
                // nudge; how long the Mac has actually been held awake is a
                // different number as soon as the two diverge, and they diverge
                // in the ordinary case: this nudge waits for `isOnBattery`, so a
                // session that spends all afternoon plugged in and is then
                // unplugged nudges on the first tick after that — reporting "2
                // hours" for a six-hour session would be telling the user
                // something they can see is false.
                notices.append(.untimedOnBatteryNudge(hours: Int(heldSoFar / 3600)))
            }

            // Stall observation. Recording only at firing time throws away the
            // early warning: a freeze that recovers on its own releases nothing
            // and leaves no trace, yet it is the same defect as the one that
            // later freezes for hours. Latched so one episode produces one
            // record instead of one per tick for as long as it lasts — and
            // `mainHeartbeat()` clears that latch, so a main actor that comes
            // back and later goes quiet again is a second episode and earns a
            // second record.
            let stallNow = seconds(now &- current.lastMainHeartbeatUptime)
            if stallNow > Self.stallThreshold, !current.stallLatched {
                current.stallLatched = true
                notices.append(.stallObserved(WatchdogStall(
                    observedAt: wallClock(), side: .mainActor, seconds: stallNow
                )))
            }

            // Commit before unlocking. Unlike Pass 5, this needs no `armEpoch`
            // re-check: `current` was read from `armed` in this same critical
            // section with no unlocked window in between, so there is no
            // opportunity for the session to have been ended or replaced
            // underneath it. Committing here rather than after the emit loop is
            // what makes both latches stick — a `current` that is mutated and
            // then dropped would re-send the same nudge and re-record the same
            // stall episode on every tick, forever.
            armed = current
            lock.unlock()

            // Emitting is IO (a disk append plus arbitrary subscriber work), so
            // it happens unlocked, exactly like the firing record at the bottom
            // of this method. Neither of these events releases anything, so
            // `releaser()` and the `releasingEpoch` handshake are not involved
            // at all: there is no assertion in flight for `arm()`/`disarm()` to
            // have to wait on.
            for notice in notices {
                evidence.append(notice)   // disk first: main may never come back
                subject.send(notice)
            }
            return
        }

        let assertionsToRelease = current.assertions
        let wasFiringReported = current.firingReported
        let mode = current.mode
        let sessionStart = current.startedAtWall
        let heldSeconds = seconds(now &- current.startedAtUptime)
        let stallSeconds = seconds(now &- current.lastMainHeartbeatUptime)
        // Mark this epoch as "releasing" before giving up the lock, so a
        // concurrent `arm()`/`disarm()` sees it and waits instead of also
        // calling `releaser()` on these same assertions. Deliberately not set
        // before Pass 2: most ticks that sample never release, and parking a
        // main-actor `arm()`/`disarm()` behind every routine battery sample
        // would spend the very budget those waits exist to protect.
        releasingEpoch = epoch
        lock.unlock()

        // Pass 4: unlocked IO. This is the part that can genuinely block —
        // real mach IPC to powerd, IOKit battery queries, log writes — and
        // none of it needs the lock.
        var statuses: [Int32] = []
        var stillHeld: [SleepAssertion] = []
        for assertion in assertionsToRelease {
            let status = releaser(assertion)
            statuses.append(status)
            // A failed release must stay armed and be retried. Clearing it
            // would leave the record, the reconcile and `isActive` all
            // claiming "released" while the kernel still holds it — a
            // silent return to the exact F-003 symptom with nothing left
            // to retry.
            if status != kIOReturnSuccess { stillHeld.append(assertion) }
        }

        var eventToEmit: WatchdogEvent?
        // The retry-only tick (neither rule currently tripped, reached solely
        // because `firingReported` is set) always lands in the `else` branch,
        // which is what keeps `reason` honest: the ternary below can only ever
        // evaluate on a tick where a rule genuinely tripped, since
        // `!wasFiringReported` means Pass 3's guard was satisfied by
        // `batteryLapsed || deadlineLapsed` and nothing else. A retry never
        // relabels the original firing, and never emits a second one.
        if !wasFiringReported {
            // Reuse Pass 2's sample when there was one, so the record shows the
            // very reading the battery rule fired on rather than a second,
            // slightly later query that may already read differently. Only the
            // no-threshold deadline path pays for a sample here.
            let sample = reading ?? sampler()
            eventToEmit = .fired(WatchdogFiring(
                firedAt: wallClock(),
                reason: batteryLapsed ? .batteryBelowThreshold : .stalled,
                mode: mode,
                sessionStart: sessionStart,
                heldSeconds: heldSeconds,
                mainStallSeconds: stallSeconds,
                batteryPercent: sample.percent,
                isOnBattery: sample.isOnBattery,
                assertionIDs: assertionsToRelease.map(\.id),
                releaseStatuses: statuses
            ))
        } else {
            AppLog.shared.log(
                "AwakeWatchdog: retrying \(stillHeld.count) failed assertion release(s)",
                level: .warn
            )
        }

        // Pass 5: commit under lock, but only if the session we just acted on
        // is still the one that's armed. `armEpoch` changes on every arm()/
        // disarm(), so a mismatch here means the caller ended or replaced this
        // session while the IO above was in flight — writing `stillHeld` back
        // in that case would resurrect a session that was deliberately ended,
        // or corrupt an unrelated new one. The release calls above already ran
        // for real regardless; only the in-memory bookkeeping is skipped.
        lock.lock()
        if armEpoch == epoch, var latest = armed {
            if stillHeld.isEmpty {
                armed = nil
                batteryBelowSinceUptime = nil
            } else {
                latest.assertions = stillHeld
                if !wasFiringReported { latest.firingReported = true }
                armed = latest
            }
        }
        // Clear the in-flight marker and wake anyone parked in `arm()`/
        // `disarm()`'s wait loop above — the release this epoch was doing is
        // now fully resolved, one way or the other.
        releasingEpoch = nil
        lock.broadcast()
        lock.unlock()

        if let event = eventToEmit {
            evidence.append(event)   // disk first: main may never come back
            subject.send(event)
        }
    }

    // MARK: Units

    private func nanos(_ seconds: TimeInterval) -> UInt64 {
        UInt64((seconds * 1_000_000_000).rounded())
    }

    private func seconds(_ nanos: UInt64) -> TimeInterval {
        TimeInterval(nanos) / 1_000_000_000
    }
}
