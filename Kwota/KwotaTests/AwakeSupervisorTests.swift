//
//  AwakeSupervisorTests.swift
//  KwotaTests
//

import XCTest
import Combine
import IOKit
@testable import Kwota

@MainActor
final class AwakeSupervisorTests: XCTestCase {
    var caffeine: CaffeinateManager!
    var holder: MockSleepAssertionHolder!
    var activity: AwakeActivityStub!
    var battery: FakeBatteryMonitor!
    var notifier: FakeAwakeNotifier!
    var configStore: AwakeConfigStore!
    var defaults: UserDefaults!
    var suite: String!
    /// Per-test-instance NotificationCenter so the supervisor only observes
    /// notifications this suite posts. Prevents parallel test cross-talk
    /// with other suites that instantiate live supervisors / watchers /
    /// MenuBarViewModels subscribed to `NSWorkspace.shared.notificationCenter`.
    var notificationCenter: NotificationCenter!
    var userInput: FakeUserInputMonitor!
    var watchdog: FakeAwakeWatchdog!

    override func setUp() async throws {
        suite = "AwakeSupervisorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        configStore = AwakeConfigStore(defaults: defaults)
        holder = MockSleepAssertionHolder()
        // One watchdog shared by the manager and the supervisor: the manager
        // arms/disarms it, the supervisor bumps its deadline and reacts to its
        // events. Two instances would let `caffeine.disable()` disarm a
        // watchdog nobody under test is asserting on.
        watchdog = FakeAwakeWatchdog()
        caffeine = CaffeinateManager(holder: holder, watchdog: watchdog)
        activity = AwakeActivityStub()
        battery = FakeBatteryMonitor()
        notifier = FakeAwakeNotifier()
        notificationCenter = NotificationCenter()
        userInput = FakeUserInputMonitor()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testInitialState_isIdle() {
        let sup = makeSupervisor()
        XCTAssertEqual(sup.state, .idle)
    }

    func testJSONLActivity_idleToAutoActive() async {
        let sup = makeSupervisor()
        let now = Date()
        activity.emit(at: now)
        await Task.yield(); await Task.yield()

        guard case .autoActive(let since) = sup.state else {
            return XCTFail("expected autoActive, got \(sup.state)")
        }
        XCTAssertEqual(since.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
        // Default auto flags = idle-only (AwakeConfig.default has preventIdleSleep:true, rest false).
        XCTAssertEqual(holder.acquired.count, 1)
        XCTAssertEqual(holder.acquired[0].type, .preventIdleSleep)
    }

    func testActivity_setsLastActiveProvider() async {
        let sup = makeSupervisor()
        activity.emit(provider: .claude)
        await Task.yield(); await Task.yield()
        XCTAssertEqual(sup.lastActiveProvider, .claude)
    }

    func testIdleTimer_clearsLastActiveProvider() async {
        let sup = makeSupervisor(idleWindowOverride: 0.05)  // 50ms
        activity.emit()
        await Task.yield(); await Task.yield()
        XCTAssertEqual(sup.lastActiveProvider, .claude)

        try? await Task.sleep(nanoseconds: 200_000_000)     // 200ms
        XCTAssertEqual(sup.state, .idle)
        XCTAssertNil(sup.lastActiveProvider)
    }

    func testBatteryBlock_clearsLastActiveProvider() async {
        let sup = makeSupervisor()
        activity.emit()
        await Task.yield(); await Task.yield()
        XCTAssertEqual(sup.lastActiveProvider, .claude)

        battery.emit(.init(isOnBattery: true, percent: 18))  // default threshold = 20
        await Task.yield(); await Task.yield()
        XCTAssertEqual(sup.state, .batteryBlocked)
        XCTAssertNil(sup.lastActiveProvider)
    }

    func testJSONLActivity_whenAutoDisabled_doesNothing() async {
        var cfg = AwakeConfig.default
        cfg.autoEnabled = false
        let sup = makeSupervisor(config: cfg)
        activity.emit()
        await Task.yield(); await Task.yield()
        XCTAssertEqual(sup.state, .idle)
        XCTAssertTrue(holder.acquired.isEmpty)
    }

    func testRepeatedJSONLEvents_doNotRestartCaffeinate() async {
        let sup = makeSupervisor()
        activity.emit(); await Task.yield(); await Task.yield()
        activity.emit(); await Task.yield(); await Task.yield()
        activity.emit(); await Task.yield(); await Task.yield()

        if case .autoActive = sup.state {
        } else { XCTFail("expected autoActive, got \(sup.state)") }
        XCTAssertEqual(holder.acquired.count, 1)
    }

    func testIdleTimer_autoActiveToIdleAfterWindow() async {
        let sup = makeSupervisor(idleWindowOverride: 0.05)  // 50ms
        activity.emit()
        await Task.yield(); await Task.yield()
        XCTAssertNotEqual(sup.state, .idle)

        try? await Task.sleep(nanoseconds: 200_000_000)     // 200ms
        XCTAssertEqual(sup.state, .idle)
        XCTAssertEqual(holder.released.count, holder.acquired.count)
        XCTAssertEqual(notifier.calls.count, 1)
        if case .agentIdle = notifier.calls[0] {
        } else { XCTFail("expected agentIdle reason") }
    }

    func testIdleTimer_resetByNewActivity() async {
        let sup = makeSupervisor(idleWindowOverride: 0.15)  // 150ms
        activity.emit()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 80_000_000)      // 80ms — under window
        activity.emit()                                     // reset
        await Task.yield()
        try? await Task.sleep(nanoseconds: 80_000_000)      // 80ms — only 80ms since reset
        if case .autoActive = sup.state {
        } else { XCTFail("expected autoActive, got \(sup.state)") }

        try? await Task.sleep(nanoseconds: 200_000_000)     // past reset window
        XCTAssertEqual(sup.state, .idle)
    }

    func testForceStart_fromIdle_movesToManualActive() async {
        let sup = makeSupervisor()
        sup.setAutoEnabled(false)
        let result = sup.forceStart(options: .default, timeout: nil)
        if case .failure = result { XCTFail("expected success") }
        if case .manualActive(_, let t) = sup.state {
            XCTAssertNil(t)
        } else { XCTFail("expected manualActive") }
        // .default = all flags true: display + idle + system acquired; declareUserActivity fired once.
        XCTAssertEqual(holder.acquired.count, 3)
        XCTAssertEqual(holder.declareUserActivityCount, 1)
    }

    func testForceStop_returnsToIdle_noNotification() async {
        let sup = makeSupervisor()
        sup.setAutoEnabled(false)
        _ = sup.forceStart(options: .default, timeout: nil)
        sup.forceStop()
        XCTAssertEqual(sup.state, .idle)
        XCTAssertTrue(notifier.calls.isEmpty)
    }

    func testCaffeinateSelfExitInManual_postsNotification() async {
        let sup = makeSupervisor()
        sup.setAutoEnabled(false)
        // Use a 1-second timeout so the manager auto-disables after the timeout
        // fires, simulating the session ending without the user stopping it.
        _ = sup.forceStart(options: .default, timeout: 1)
        XCTAssertEqual(holder.acquired.count, 3)

        // Wait for the timeout task to fire and auto-disable.
        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s

        XCTAssertEqual(sup.state, .idle)
        XCTAssertEqual(notifier.calls.count, 1)
        if case .forceTimeoutElapsed = notifier.calls[0] {
        } else { XCTFail("expected forceTimeoutElapsed") }
    }

    func testForceStart_failurePath_leavesIdle() async throws {
        let sup = makeSupervisor()
        sup.setAutoEnabled(false)

        // Make the next acquire() call throw to force the catch path.
        struct FakeError: Error {}
        holder.nextAcquireError = FakeError()
        let result = sup.forceStart(options: .default, timeout: nil)
        if case .failure(.launchFailed) = result {} else {
            XCTFail("expected .launchFailed, got \(result)")
        }

        XCTAssertEqual(sup.state, .idle)
        // Allow Combine delivery to drain.
        await Task { @MainActor in }.value
        XCTAssertEqual(sup.state, .idle)
    }

    func testBatteryBelowThreshold_onBattery_stopsAutoActive() async {
        let sup = makeSupervisor()
        activity.emit()
        await Task.yield(); await Task.yield()
        if case .autoActive = sup.state {} else { return XCTFail() }

        battery.emit(.init(isOnBattery: true, percent: 18))  // default threshold = 20
        await Task.yield(); await Task.yield()

        XCTAssertEqual(sup.state, .batteryBlocked)
        XCTAssertEqual(holder.released.count, holder.acquired.count)
        XCTAssertEqual(notifier.calls.count, 1)
        if case .batteryBelowThreshold(let cur, let thresh) = notifier.calls[0] {
            XCTAssertEqual(cur, 18)
            XCTAssertEqual(thresh, 20)
        } else { XCTFail("expected batteryBelowThreshold") }
    }

    func testBatteryRecovery_returnsToIdle() async {
        let sup = makeSupervisor()
        activity.emit(); await Task.yield(); await Task.yield()
        battery.emit(.init(isOnBattery: true, percent: 18))
        await Task.yield(); await Task.yield()
        XCTAssertEqual(sup.state, .batteryBlocked)

        battery.emit(.init(isOnBattery: false, percent: 18))  // plugged in
        await Task.yield(); await Task.yield()

        XCTAssertEqual(sup.state, .idle)
    }

    func testBatteryOff_ignoresLowReading() async {
        var cfg = AwakeConfig.default
        cfg.batteryThreshold = .off
        let sup = makeSupervisor(config: cfg)
        activity.emit(); await Task.yield(); await Task.yield()

        battery.emit(.init(isOnBattery: true, percent: 5))
        await Task.yield(); await Task.yield()

        if case .autoActive = sup.state {} else { XCTFail("expected autoActive") }
    }

    func testForceStart_whenBlocked_returnsFailure() async {
        let sup = makeSupervisor()
        sup.setAutoEnabled(false)
        battery.emit(.init(isOnBattery: true, percent: 5))
        await Task.yield(); await Task.yield()
        XCTAssertEqual(sup.state, .batteryBlocked)

        let result = sup.forceStart(options: .default, timeout: nil)
        if case .failure(.batteryBelowThreshold(let cur, let thresh)) = result {
            XCTAssertEqual(cur, 5)
            XCTAssertEqual(thresh, 20)
        } else { XCTFail("expected blocked failure") }
        XCTAssertEqual(sup.state, .batteryBlocked)
    }

    func testSetAutoEnabled_falseWhileAutoActive_stopsAwake() async {
        let sup = makeSupervisor()
        activity.emit(); await Task.yield(); await Task.yield()
        if case .autoActive = sup.state {} else { return XCTFail() }

        sup.setAutoEnabled(false)
        XCTAssertEqual(sup.state, .idle)
        XCTAssertFalse(configStore.config.autoEnabled)
    }

    func testUpdateFlags_whileAutoActive_restartsCaffeinate() async {
        let sup = makeSupervisor()
        activity.emit(); await Task.yield(); await Task.yield()
        // Default auto flags = idle only.
        XCTAssertEqual(holder.acquired.count, 1)
        XCTAssertEqual(holder.acquired[0].type, .preventIdleSleep)

        var newFlags = AwakeConfig.default.flags
        newFlags.preventDisplaySleep = true
        sup.updateFlags(newFlags)
        await Task.yield(); await Task.yield()

        // Restart: the prior single assertion is released, and the new flag
        // set acquires two (display + idle). holder.acquired is cumulative —
        // 1 from the initial round + 2 from restart = 3 total. Scope the
        // contains-checks to the post-restart acquires so the assertion does
        // not pass trivially on the initial idle entry.
        XCTAssertEqual(holder.acquired.count, 3, "1 initial idle + 2 after restart (display + idle)")
        XCTAssertEqual(holder.released.count, 1, "the initial single assertion was released by the restart")
        let restartAcquired = Array(holder.acquired.suffix(2)).map(\.type)
        XCTAssertTrue(restartAcquired.contains(.preventDisplaySleep))
        XCTAssertTrue(restartAcquired.contains(.preventIdleSleep))
    }

    func testCaffeinateSelfExitInAutoActive_postsUnexpectedExitNotification() async {
        let sup = makeSupervisor()
        activity.emit(); await Task.yield(); await Task.yield()
        guard case .autoActive = sup.state else { return XCTFail() }

        // Direct caffeine.disable() bypasses the supervisor's exit-reaction
        // suppression — exactly the shape of an "unexpected exit" the
        // supervisor should report. The internal timeout path lands here too
        // (via the manager's auto-disable on timeout), so this one assertion
        // covers both surfaces.
        await MainActor.run { caffeine.disable() }
        // Drain the main-actor Combine sink.
        await Task { @MainActor in }.value

        XCTAssertEqual(sup.state, .idle)
        XCTAssertEqual(notifier.calls.count, 1)
        if case .unexpectedExit = notifier.calls[0] {
        } else { XCTFail("expected unexpectedExit, got \(notifier.calls[0])") }
    }

    func testUpdateIdleWindow_whileAutoActive_reschedulesTimer() async {
        let sup = makeSupervisor(idleWindowOverride: 10.0)  // 10s — won't fire on its own
        activity.emit()
        await Task.yield(); await Task.yield()
        guard case .autoActive = sup.state else { return XCTFail() }

        // Persist a shorter idleWindow; updateIdleWindow should reschedule
        // the timer (which uses effectiveIdleWindow = idleWindowOverride for
        // tests). Set the override directly by re-creating? No — the test
        // verifies the reschedule call path, which goes through
        // rescheduleIdleTimer. We assert by behavior: the timer is still
        // armed (state still autoActive after a short sleep).
        sup.updateIdleWindow(.m1)
        XCTAssertEqual(configStore.config.idleWindow, .m1)
        // State remains autoActive (the new timer is 10s from override, not
        // 60s from config.idleWindow — but the test isn't asserting timing
        // precision, just that the reschedule path runs without error and
        // doesn't change state).
        if case .autoActive = sup.state {} else { XCTFail("expected autoActive") }
    }

    func testForceStart_whileAutoEnabled_returnsFailureAutoEnabled() {
        let sup = makeSupervisor()
        XCTAssertTrue(configStore.config.autoEnabled, "fixture precondition")

        let result = sup.forceStart(options: configStore.config.flags, timeout: nil)

        guard case .failure(.autoEnabled) = result else {
            return XCTFail("expected .failure(.autoEnabled), got \(result)")
        }
        XCTAssertEqual(sup.state, .idle, "guard must be a no-op")
        XCTAssertTrue(holder.acquired.isEmpty,
                      "guard must not acquire sleep assertions")
    }

    func testSetAutoEnabled_true_whileManualActive_stopsManual() {
        let sup = makeSupervisor()
        sup.setAutoEnabled(false)
        let result = sup.forceStart(options: configStore.config.flags, timeout: 3600)
        guard case .success = result else { return XCTFail("manual start failed") }
        guard case .manualActive = sup.state else {
            return XCTFail("expected manualActive, got \(sup.state)")
        }

        sup.setAutoEnabled(true)

        XCTAssertEqual(sup.state, .idle,
                       "manual session must be stopped when auto is re-enabled")
        XCTAssertTrue(configStore.config.autoEnabled)
    }

    // MARK: Sleep/wake callbacks

    /// `willSleepNotification` must fire the `onWillSleep` callback with the
    /// current state so the consumer (the VM, in production) can close any
    /// open `AwakeSession` at the sleep moment.
    func testOnWillSleep_firesCallbackWithCurrentState() async {
        var fired: [(Date, AwakeState)] = []
        let sup = makeSupervisor(onWillSleep: { date, state in
            fired.append((date, state))
        })
        // Drive supervisor into autoActive so the callback receives that.
        activity.emit()
        await Task.yield(); await Task.yield()
        guard case .autoActive = sup.state else { return XCTFail("setup") }

        notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        await Task.yield(); await Task.yield()

        XCTAssertEqual(fired.count, 1)
        if case .autoActive = fired[0].1 {} else {
            XCTFail("expected autoActive, got \(fired[0].1)")
        }
    }

    /// On wake, the callback must observe the *post-evaluation* state. If
    /// battery dropped during sleep, `onBatteryChange` fires inside
    /// `onSystemWake` and may transition to `.batteryBlocked`; the wake
    /// callback should see that, not the pre-wake state.
    func testOnDidWakeFromSleep_firesCallbackAfterBatteryReEvaluation() async {
        var fired: [(Date, AwakeState)] = []
        let sup = makeSupervisor(onDidWakeFromSleep: { date, state in
            fired.append((date, state))
        })
        activity.emit()
        await Task.yield(); await Task.yield()
        guard case .autoActive = sup.state else { return XCTFail("setup") }

        // Drop battery below threshold so onSystemWake's battery re-eval
        // transitions state to .batteryBlocked BEFORE the callback fires.
        battery.emit(.init(isOnBattery: true, percent: 5))
        await Task.yield(); await Task.yield()
        guard case .batteryBlocked = sup.state else { return XCTFail("battery") }

        notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        await Task.yield(); await Task.yield()

        XCTAssertEqual(fired.count, 1)
        if case .batteryBlocked = fired[0].1 {} else {
            XCTFail("expected batteryBlocked post-eval, got \(fired[0].1)")
        }
    }

    /// Callbacks must fire regardless of state; the consumer decides what to
    /// do. Idle sleep is a no-op for session-log writes, but the supervisor
    /// shouldn't suppress the signal.
    func testOnWillSleep_firesEvenWhenIdle() async {
        var fired = false
        let sup = makeSupervisor(onWillSleep: { _, _ in fired = true })
        XCTAssertEqual(sup.state, .idle, "fixture starts idle")

        notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        await Task.yield(); await Task.yield()

        XCTAssertTrue(fired)
    }

    // MARK: User-idle gate

    func testGate_userAtKeyboard_blocksAutoActivation() async {
        userInput.idleSeconds = 10   // default gate is .m1 (60s)
        let sup = makeSupervisor()
        activity.emit()
        await Task.yield(); await Task.yield()
        XCTAssertEqual(sup.state, .idle)
        XCTAssertTrue(holder.acquired.isEmpty,
                      "no assertion while the user is actively at the Mac")
    }

    func testGate_userAway_allowsActivation() async {
        userInput.idleSeconds = 90
        let sup = makeSupervisor()
        activity.emit()
        await Task.yield(); await Task.yield()
        if case .autoActive = sup.state {
        } else { XCTFail("expected autoActive, got \(sup.state)") }
        XCTAssertEqual(holder.acquired.count, 1)
    }

    func testGate_off_activatesRegardlessOfUserPresence() async {
        var cfg = AwakeConfig.default
        cfg.userIdleGate = .off
        userInput.idleSeconds = 0
        let sup = makeSupervisor(config: cfg)
        activity.emit()
        await Task.yield(); await Task.yield()
        if case .autoActive = sup.state {
        } else { XCTFail("expected autoActive, got \(sup.state)") }
    }

    func testUserReturn_releasesAutoSession_silently() async {
        userInput.idleSeconds = 999
        let sup = makeSupervisor()
        activity.emit()
        await Task.yield(); await Task.yield()
        if case .autoActive = sup.state {
        } else { return XCTFail("precondition: expected autoActive") }

        userInput.idleSeconds = 0   // user touched the keyboard
        try? await Task.sleep(nanoseconds: 200_000_000)   // > poll interval

        XCTAssertEqual(sup.state, .idle)
        XCTAssertNil(sup.lastActiveProvider)
        XCTAssertEqual(holder.released.count, holder.acquired.count,
                       "assertion must drop when the user returns")
        XCTAssertTrue(notifier.calls.isEmpty,
                      "user-return stop must not notify — the user caused it")
    }

    func testUserReturn_thenAwayAgain_reactivatesOnNextPulse() async {
        userInput.idleSeconds = 999
        let sup = makeSupervisor()
        activity.emit()
        await Task.yield(); await Task.yield()

        userInput.idleSeconds = 0
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sup.state, .idle)

        userInput.idleSeconds = 999   // user walked away again
        activity.emit()
        await Task.yield(); await Task.yield()
        if case .autoActive = sup.state {
        } else { XCTFail("expected re-activation, got \(sup.state)") }
        XCTAssertEqual(holder.acquired.count, 2)
    }

    func testGate_doesNotAffectManualMode() async {
        var cfg = AwakeConfig.default
        cfg.autoEnabled = false
        userInput.idleSeconds = 0    // user is at the keyboard
        let sup = makeSupervisor(config: cfg)
        let result = sup.forceStart(options: CaffeinateOptions(
            preventDisplaySleep: false,
            preventIdleSleep: true,
            preventSystemSleep: false,
            declareUserActivity: false
        ), timeout: nil)
        XCTAssertNoThrow(try result.get())
        if case .manualActive = sup.state {
        } else { XCTFail("manual start must ignore the user-idle gate") }
    }

    func testUpdateUserIdleGate_toOff_stopsReleasePolling() async {
        userInput.idleSeconds = 999
        let sup = makeSupervisor()
        activity.emit()
        await Task.yield(); await Task.yield()

        sup.updateUserIdleGate(.off)
        userInput.idleSeconds = 0    // user returns — but gate is now off
        try? await Task.sleep(nanoseconds: 200_000_000)
        if case .autoActive = sup.state {
        } else { XCTFail("gate off must stop user-return releases, got \(sup.state)") }
    }

    // MARK: watchdog reconcile

    func testWatchdogStallFiring_goesIdleWithOneNotification() async {
        let sup = makeSupervisor()
        activity.emit(at: Date())
        await Task.yield(); await Task.yield()
        XCTAssertTrue(caffeine.isActive)

        watchdog.subject.send(.fired(WatchdogFiring(
            firedAt: Date(timeIntervalSince1970: 500),
            reason: .stalled, mode: .auto,
            sessionStart: Date(timeIntervalSince1970: 0),
            heldSeconds: 500, mainStallSeconds: 400,
            batteryPercent: 90, isOnBattery: false,
            assertionIDs: [1], releaseStatuses: [0]
        )))
        await Task.yield(); await Task.yield(); await Task.yield()

        XCTAssertEqual(sup.state, .idle)
        XCTAssertFalse(caffeine.isActive)
        XCTAssertEqual(notifier.calls.count, 1, "the isActive sink must not add a second one")
        guard case .watchdogStalled = notifier.calls.first else {
            return XCTFail("expected watchdogStalled, got \(notifier.calls)")
        }
    }

    func testWatchdogBatteryFiring_goesBatteryBlocked() async {
        let sup = makeSupervisor()
        activity.emit(at: Date())
        await Task.yield(); await Task.yield()

        watchdog.subject.send(.fired(WatchdogFiring(
            firedAt: Date(timeIntervalSince1970: 500),
            reason: .batteryBelowThreshold, mode: .auto,
            sessionStart: Date(timeIntervalSince1970: 0),
            heldSeconds: 500, mainStallSeconds: 0,
            batteryPercent: 15, isOnBattery: true,
            assertionIDs: [1], releaseStatuses: [0]
        )))
        await Task.yield(); await Task.yield(); await Task.yield()

        XCTAssertEqual(sup.state, .batteryBlocked)
        guard case .batteryBelowThreshold(let cur, _) = notifier.calls.first else {
            return XCTFail("expected batteryBelowThreshold, got \(notifier.calls)")
        }
        XCTAssertEqual(cur, 15)
    }

    func testWatchdogFiring_closesSessionAtFiredAtNotNow() async {
        var closedAt: Date?
        let sup = makeSupervisor(onForcedRelease: { date, _ in closedAt = date })
        activity.emit(at: Date())
        await Task.yield(); await Task.yield()

        let firedAt = Date(timeIntervalSince1970: 500)
        watchdog.subject.send(.fired(WatchdogFiring(
            firedAt: firedAt, reason: .stalled, mode: .auto,
            sessionStart: Date(timeIntervalSince1970: 0),
            heldSeconds: 500, mainStallSeconds: 400,
            batteryPercent: nil, isOnBattery: false,
            assertionIDs: [1], releaseStatuses: [0]
        )))
        await Task.yield(); await Task.yield(); await Task.yield()

        XCTAssertEqual(closedAt, firedAt, "closing at recovery time would paint a phantom tint")
        _ = sup
    }

    func testNudgeEventNotifiesAndChangesNothing() async {
        let sup = makeSupervisor()
        activity.emit(at: Date())
        await Task.yield(); await Task.yield()
        let before = sup.state

        watchdog.subject.send(.untimedOnBatteryNudge(hours: 2))
        await Task.yield(); await Task.yield()

        XCTAssertEqual(notifier.untimedCalls, [2])
        XCTAssertEqual(sup.state, before)
        XCTAssertTrue(caffeine.isActive, "a nudge must never release")
    }

    func testStallObservedEventChangesNothing() async {
        let sup = makeSupervisor()
        activity.emit(at: Date())
        await Task.yield(); await Task.yield()

        watchdog.subject.send(.stallObserved(WatchdogStall(
            observedAt: Date(), side: .mainActor, seconds: 240
        )))
        await Task.yield(); await Task.yield()

        XCTAssertTrue(caffeine.isActive)
        XCTAssertTrue(notifier.calls.isEmpty)
        _ = sup
    }

    /// Main recovered through some other path before the firing was delivered.
    /// The evidence record already exists; re-notifying would double-report a
    /// single event.
    func testFiringWhileAlreadyIdle_isANoOp() async {
        let sup = makeSupervisor()
        XCTAssertEqual(sup.state, .idle)

        watchdog.subject.send(.fired(WatchdogFiring(
            firedAt: Date(timeIntervalSince1970: 500),
            reason: .stalled, mode: .auto,
            sessionStart: Date(timeIntervalSince1970: 0),
            heldSeconds: 500, mainStallSeconds: 400,
            batteryPercent: nil, isOnBattery: false,
            assertionIDs: [1], releaseStatuses: [0]
        )))
        await Task.yield(); await Task.yield()

        XCTAssertEqual(sup.state, .idle)
        XCTAssertTrue(notifier.calls.isEmpty)
    }

    /// The F-003 recovery race, end to end across all three types.
    ///
    /// Main is blocked for hours; the watchdog fires from its own queue,
    /// releases cleanly, ends its session and stops ticking. Main then recovers,
    /// and the manager's heartbeat continuation — enqueued before the stall
    /// began — runs *first*, ahead of the `.fired` event, which only reaches the
    /// main run loop at firing time. If the mutual watch still saw an age
    /// measured from the firing, it would call `disable()` here, flip
    /// `caffeine.$isActive` without the supervisor's suppression flag, and land
    /// the supervisor in `.idle` — after which `adoptWatchdogFiring` no-ops:
    /// `.unexpectedExit` instead of `.watchdogStalled`, and no session close at
    /// `firedAt`, so the awake tint stretches across the entire stall again.
    func testStaleHeartbeatAfterAFiringDoesNotPreemptTheAdoptPath() async {
        // Short heartbeat so the mutual watch gets many chances to misfire in
        // the window below. Rebuilt here rather than in setUp because every
        // other test in this suite wants the production 60s cadence, which
        // never fires inside a test.
        caffeine = CaffeinateManager(holder: holder, watchdog: watchdog, heartbeatInterval: 0.02)
        var closedAt: Date?
        let sup = makeSupervisor(onForcedRelease: { date, _ in closedAt = date })
        activity.emit(at: Date())
        await Task.yield(); await Task.yield()
        XCTAssertTrue(caffeine.isActive)

        // The watchdog fired and stopped ticking; its last tick is now as old as
        // the stall. No await between the two, so no heartbeat can slip in while
        // the fake still reports itself armed.
        watchdog.stubbedLastTickAge = 3 * 3600
        watchdog.simulateCleanFiring()

        // Main "recovers": heartbeats run for a while before the event lands.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(caffeine.isActive, "the mutual watch must not have released")
        XCTAssertTrue(notifier.calls.isEmpty, "and must not have reported a stop")

        let firedAt = Date(timeIntervalSince1970: 500)
        watchdog.subject.send(.fired(WatchdogFiring(
            firedAt: firedAt, reason: .stalled, mode: .auto,
            sessionStart: Date(timeIntervalSince1970: 0),
            heldSeconds: 10_800, mainStallSeconds: 10_700,
            batteryPercent: nil, isOnBattery: false,
            assertionIDs: [1], releaseStatuses: [0]
        )))
        await Task.yield(); await Task.yield(); await Task.yield()

        XCTAssertEqual(sup.state, .idle)
        XCTAssertFalse(caffeine.isActive)
        XCTAssertEqual(notifier.calls.count, 1)
        guard case .watchdogStalled = notifier.calls.first else {
            return XCTFail("expected watchdogStalled, got \(notifier.calls)")
        }
        XCTAssertEqual(closedAt, firedAt, "the session must close at the firing, not at recovery")
    }

    // MARK: deadline bumps and threshold push

    func testActivityBumpsTheWatchdogDeadline() async {
        let sup = makeSupervisor()
        activity.emit(at: Date())
        await Task.yield(); await Task.yield()

        XCTAssertEqual(watchdog.bumps.last, AwakeConfig.default.idleWindow.seconds)
        _ = sup
    }

    func testThresholdIsPushedOnInitAndOnChange() {
        let sup = makeSupervisor()
        XCTAssertEqual(watchdog.thresholds.first, 20, "AwakeConfig.default is p20")

        sup.updateBatteryThreshold(.p10)
        XCTAssertEqual(watchdog.thresholds.last, 10)
    }

    /// A firing whose releases partly failed must not be adopted — the manager
    /// has to release the straggler through its own holder. Adopting on a false
    /// premise is the one path in this design that recreates F-003.
    func testPartialFailureFiringReleasesThroughTheHolder() async {
        let sup = makeSupervisor()
        activity.emit(at: Date())
        await Task.yield(); await Task.yield()
        let heldBefore = holder.released.count

        watchdog.subject.send(.fired(WatchdogFiring(
            firedAt: Date(timeIntervalSince1970: 500),
            reason: .stalled, mode: .auto,
            sessionStart: Date(timeIntervalSince1970: 0),
            heldSeconds: 500, mainStallSeconds: 400,
            batteryPercent: nil, isOnBattery: false,
            assertionIDs: [1], releaseStatuses: [-1]
        )))
        await Task.yield(); await Task.yield(); await Task.yield()

        XCTAssertEqual(sup.state, .idle)
        XCTAssertGreaterThan(holder.released.count, heldBefore,
                             "a straggler must be released, not adopted away")
    }

    // MARK: full chain, no fakes between the three types

    /// The only test that composes a **real** `AwakeWatchdog`, a real
    /// `CaffeinateManager` and a real `AwakeSupervisor` the way `KwotaApp` wires
    /// them — one watchdog instance shared by the manager that arms it and the
    /// supervisor that reacts to it — and drives a single firing through the
    /// whole chain: arm → tick → off-main release → evidence record → adopt →
    /// session close.
    ///
    /// Every other test here stubs at least one seam, which is how a defect that
    /// only exists *between* the types (a heartbeat check that could not tell a
    /// fired watchdog from a dead one) stayed invisible through several rounds
    /// of task-scoped review.
    func testRealWatchdogFiring_flowsThroughManagerAndSupervisor() async {
        let released = ReleasedAssertionRecorder()
        let uptime = StubUptime()
        let evidence = RecordingWatchdogEvidence()
        // The moment the watchdog fires, in wall-clock terms. Deliberately far
        // from `Date()` so a session closed at "now" instead of at the firing
        // cannot pass by coincidence.
        let firedAt = Date(timeIntervalSince1970: 1_000)
        let real = AwakeWatchdog(
            // Zero grace so an injected uptime can pass the deadline without
            // also having to step over the production two-minute cushion.
            deadlineGrace: 0,
            uptime: { uptime.now() },
            wallClock: { firedAt },
            releaser: { released.record($0); return kIOReturnSuccess },
            sampler: { BatteryReading(isOnBattery: false, percent: 90) },
            evidence: evidence,
            autoStartTimer: false
        )
        caffeine = CaffeinateManager(holder: holder, watchdog: real)
        var closedAt: Date?
        // 300s idle window so the in-process idle timer — the path the watchdog
        // is a backstop for — cannot fire during the test and steal the release.
        let sup = makeSupervisor(
            idleWindowOverride: 300,
            watchdog: real,
            onForcedRelease: { date, _ in closedAt = date }
        )

        activity.emit(at: Date())
        await Task.yield(); await Task.yield()
        XCTAssertTrue(caffeine.isActive)
        XCTAssertEqual(holder.acquired.count, 1, "AwakeConfig.default is idle-only")

        // Main actor is blocked from here: no heartbeats, and the idle timer
        // never gets to run. Only the watchdog's own queue is alive, which in
        // production is what delivers this tick.
        uptime.advance(301)
        real.tick()

        // The kernel-side release already happened, entirely off the main actor.
        XCTAssertEqual(released.assertions.map(\.id), [1])
        XCTAssertEqual(evidence.events.count, 1, "one firing, recorded to disk first")
        guard case .fired(let firing)? = evidence.events.first else {
            return XCTFail("expected a firing, got \(evidence.events)")
        }
        XCTAssertEqual(firing.reason, .stalled)
        XCTAssertEqual(firing.mode, .auto)
        XCTAssertEqual(firing.mainStallSeconds, 301, accuracy: 0.001)
        XCTAssertEqual(firing.releaseStatuses, [kIOReturnSuccess])

        // Main recovers and the event finally lands.
        await Task.yield(); await Task.yield(); await Task.yield()

        XCTAssertEqual(sup.state, .idle)
        XCTAssertFalse(caffeine.isActive)
        XCTAssertTrue(holder.released.isEmpty, "adopted, not double-released")
        XCTAssertEqual(closedAt, firedAt, "the tint must end at the firing, not at recovery")
        XCTAssertEqual(notifier.calls.count, 1)
        guard case .watchdogStalled(let heldMinutes) = notifier.calls.first else {
            return XCTFail("expected watchdogStalled, got \(notifier.calls)")
        }
        XCTAssertEqual(heldMinutes, 5)
    }

    // MARK: termination

    func testPrepareForTerminationReleasesSilently() async {
        var closedAt: Date?
        let sup = makeSupervisor(onForcedRelease: { date, _ in closedAt = date })
        activity.emit(at: Date())
        await Task.yield(); await Task.yield()
        XCTAssertTrue(caffeine.isActive)

        let quitAt = Date(timeIntervalSince1970: 900)
        sup.prepareForTermination(at: quitAt)

        XCTAssertEqual(sup.state, .idle)
        XCTAssertFalse(caffeine.isActive)
        XCTAssertEqual(closedAt, quitAt)
        XCTAssertTrue(notifier.calls.isEmpty, "quitting is not an unexpected exit")
    }

    // MARK: Helpers

    func makeSupervisor(
        config: AwakeConfig = .default,
        idleWindowOverride: TimeInterval? = nil,
        userReturnPollInterval: TimeInterval = 0.02,
        watchdog: (any AwakeWatchdogging)? = nil,
        onWillSleep: ((Date, AwakeState) -> Void)? = nil,
        onDidWakeFromSleep: ((Date, AwakeState) -> Void)? = nil,
        onForcedRelease: ((Date, AwakeState) -> Void)? = nil
    ) -> AwakeSupervisor {
        configStore.update(config)
        return AwakeSupervisor(
            caffeine: caffeine,
            activity: activity,
            battery: battery,
            notifier: notifier,
            configStore: configStore,
            idleWindowOverride: idleWindowOverride,
            userInput: userInput,
            userReturnPollInterval: userReturnPollInterval,
            // Defaults to the suite's shared instance — the same one the
            // manager was built with, so `caffeine.disable()` reaches it. A
            // default *parameter* cannot reference an instance property, which
            // is why this resolves in the body.
            watchdog: watchdog ?? self.watchdog,
            notificationCenter: notificationCenter,
            onWillSleep: onWillSleep,
            onDidWakeFromSleep: onDidWakeFromSleep,
            onForcedRelease: onForcedRelease
        )
    }
}

// MARK: - Doubles for the full-chain integration test
//
// `AwakeWatchdog` takes `@Sendable` closures and calls them from its own queue,
// so these are locked rather than plain vars — even though this test drives the
// tick synchronously, the type is free to hand the work to `queue` and the
// compiler holds us to it.

final class StubUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var nanos: UInt64 = 1_000_000_000

    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return nanos }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        nanos &+= UInt64(seconds * 1_000_000_000)
    }
}

final class ReleasedAssertionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _assertions: [SleepAssertion] = []

    var assertions: [SleepAssertion] { lock.lock(); defer { lock.unlock() }; return _assertions }

    func record(_ assertion: SleepAssertion) {
        lock.lock(); defer { lock.unlock() }
        _assertions.append(assertion)
    }
}

final class RecordingWatchdogEvidence: WatchdogEvidenceWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [WatchdogEvent] = []

    var events: [WatchdogEvent] { lock.lock(); defer { lock.unlock() }; return _events }

    func append(_ event: WatchdogEvent) {
        lock.lock(); defer { lock.unlock() }
        _events.append(event)
    }
}

@MainActor
final class FakeUserInputMonitor: UserInputIdleProviding {
    /// Defaults to "away forever" so pre-gate tests keep their behavior.
    var idleSeconds: TimeInterval = .infinity
    func secondsSinceLastInput() -> TimeInterval { idleSeconds }
}

@MainActor
final class AwakeActivityStub: ActivitySource {
    private let subject = PassthroughSubject<ActivityEvent, Never>()

    var activityPublisher: AnyPublisher<ActivityEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    func emit(at date: Date = Date(), provider: ProviderID = .claude) {
        subject.send(ActivityEvent(date: date, provider: provider, kind: .agentResponse))
    }
}
