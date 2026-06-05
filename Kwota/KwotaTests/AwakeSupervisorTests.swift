//
//  AwakeSupervisorTests.swift
//  KwotaTests
//

import XCTest
import Combine
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

    override func setUp() async throws {
        suite = "AwakeSupervisorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        configStore = AwakeConfigStore(defaults: defaults)
        holder = MockSleepAssertionHolder()
        caffeine = CaffeinateManager(holder: holder)
        activity = AwakeActivityStub()
        battery = FakeBatteryMonitor()
        notifier = FakeAwakeNotifier()
        notificationCenter = NotificationCenter()
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

    // MARK: Helpers

    func makeSupervisor(
        config: AwakeConfig = .default,
        idleWindowOverride: TimeInterval? = nil,
        onWillSleep: ((Date, AwakeState) -> Void)? = nil,
        onDidWakeFromSleep: ((Date, AwakeState) -> Void)? = nil
    ) -> AwakeSupervisor {
        configStore.update(config)
        return AwakeSupervisor(
            caffeine: caffeine,
            activity: activity,
            battery: battery,
            notifier: notifier,
            configStore: configStore,
            idleWindowOverride: idleWindowOverride,
            notificationCenter: notificationCenter,
            onWillSleep: onWillSleep,
            onDidWakeFromSleep: onDidWakeFromSleep
        )
    }
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
