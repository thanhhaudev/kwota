//
//  KeychainGatewayTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class KeychainGatewayTests: XCTestCase {

    private func primitives(
        copyMatching: @escaping @Sendable ([String: Any]) -> (OSStatus, AnyObject?) = { _ in (errSecItemNotFound, nil) },
        setInteractionAllowed: @escaping @Sendable (Bool) -> Void = { _ in }
    ) -> KeychainPrimitives {
        KeychainPrimitives(
            copyMatching: copyMatching,
            add: { _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess },
            setInteractionAllowed: setInteractionAllowed
        )
    }

    func test_read_returnsDataOnSuccess() async throws {
        let payload = Data("secret".utf8)
        let gateway = KeychainGateway(
            primitives: primitives(copyMatching: { _ in (errSecSuccess, payload as AnyObject) })
        )
        let out = try await gateway.read(service: "s", account: "a", interaction: .deny)
        XCTAssertEqual(out, payload)
    }

    func test_read_returnsNilWhenItemMissing() async throws {
        let gateway = KeychainGateway(primitives: primitives())
        let out = try await gateway.read(service: "s", account: "a", interaction: .deny)
        XCTAssertNil(out)
    }

    func test_read_mapsInteractionNotAllowedToItsOwnError() async {
        let gateway = KeychainGateway(
            primitives: primitives(copyMatching: { _ in (errSecInteractionNotAllowed, nil) })
        )
        do {
            _ = try await gateway.read(service: "s", account: "a", interaction: .deny)
            XCTFail("expected interactionNotAllowed")
        } catch let error as KeychainGatewayError {
            XCTAssertEqual(error, .interactionNotAllowed)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// Pins the real-world denial status code, not just an
    /// `errSecInteractionNotAllowed`-shaped synthetic one.
    /// `SecKeychainSetUserInteractionAllowed(false)` (the legacy suppression
    /// API this gateway actually uses) returns `errSecAuthFailed` (-25293)
    /// for a denied/untrusted read, empirically measured against a real
    /// Keychain item — see
    /// docs/findings/F-005-keychain-interaction-suppression.md. Before this
    /// fix, -25293 fell through to the generic `.status` branch and every
    /// denial-vs-absence consumer (the Grant banner, cache preservation)
    /// never saw a real-world denial as a denial. Do not "clean this up" to
    /// -25308 (`errSecInteractionNotAllowed`) — that is the code the modern
    /// API returns, not the one production actually hits.
    func test_read_mapsRealWorldAuthFailedStatusToInteractionNotAllowed() async {
        let realWorldDeniedStatus: OSStatus = -25293
        XCTAssertEqual(realWorldDeniedStatus, errSecAuthFailed, "sanity: pin the raw code too, in case the SDK constant ever moves")
        let gateway = KeychainGateway(
            primitives: primitives(copyMatching: { _ in (realWorldDeniedStatus, nil) })
        )
        do {
            _ = try await gateway.read(service: "s", account: "a", interaction: .deny)
            XCTFail("expected interactionNotAllowed")
        } catch let error as KeychainGatewayError {
            XCTAssertEqual(error, .interactionNotAllowed)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func test_denyDisallowsInteractionAndRestoresItAfterwards() async throws {
        let recorded = UncheckedBox<[Bool]>([])
        let gateway = KeychainGateway(
            primitives: primitives(setInteractionAllowed: { value in recorded.mutate { $0.append(value) } })
        )
        _ = try await gateway.read(service: "s", account: "a", interaction: .deny)
        XCTAssertEqual(recorded.value, [false, true])
    }

    func test_allowLeavesInteractionEnabled() async throws {
        let recorded = UncheckedBox<[Bool]>([])
        let gateway = KeychainGateway(
            primitives: primitives(setInteractionAllowed: { value in recorded.mutate { $0.append(value) } })
        )
        _ = try await gateway.read(service: "s", account: "a", interaction: .allow)
        XCTAssertEqual(recorded.value, [true, true])
    }

    func test_callerIsReleasedAtTheDeadlineWhenTheProbeNeverAnswers() async {
        let gateway = KeychainGateway(
            primitives: primitives(copyMatching: { _ in
                Thread.sleep(forTimeInterval: 30)
                return (errSecSuccess, nil)
            }),
            timeout: 0.2
        )
        let started = Date()
        do {
            _ = try await gateway.read(service: "s", account: "a", interaction: .deny)
            XCTFail("expected timedOut")
        } catch let error as KeychainGatewayError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func test_aWedgedProbeFailsLaterCallsFastInsteadOfQueueingBehindIt() async {
        let gateway = KeychainGateway(
            primitives: primitives(copyMatching: { _ in
                Thread.sleep(forTimeInterval: 30)
                return (errSecSuccess, nil)
            }),
            timeout: 0.2
        )
        _ = try? await gateway.read(service: "s", account: "a", interaction: .deny)

        let started = Date()
        do {
            _ = try await gateway.read(service: "s", account: "b", interaction: .deny)
            XCTFail("expected timedOut")
        } catch let error as KeychainGatewayError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.15,
                          "a wedged gateway must fail fast, not wait out another full deadline")
    }

    /// `.allow` exists for a real consent dialog a human is actively looking
    /// at — it must get a longer deadline than the background `timeout`, AND
    /// a parked `.allow` call must not arm `wedged`. Before this fix both a
    /// short shared deadline and an indiscriminate `wedged = true` meant an
    /// ordinary, expected Grant-flow dialog fast-failed every other Keychain
    /// caller (token refreshes, deletes, background reads) in the process
    /// until the user answered it.
    func test_parkedAllowProbeGetsLongerDeadlineAndDoesNotWedgeSubsequentDenyCalls() async {
        let gateway = KeychainGateway(
            primitives: primitives(copyMatching: { _ in
                Thread.sleep(forTimeInterval: 30)   // stands in for an unanswered dialog
                return (errSecSuccess, nil)
            }),
            timeout: 0.2,       // the short background deadline
            allowTimeout: 0.35  // .allow's own, longer deadline
        )

        let allowStarted = Date()
        do {
            _ = try await gateway.read(service: "s", account: "a", interaction: .allow)
            XCTFail("expected timedOut")
        } catch let error as KeychainGatewayError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(allowStarted), 0.3,
            "an .allow call must wait out its own longer deadline, not the short background one"
        )

        // The parked .allow probe above must not have set `wedged`: a
        // subsequent .deny call has to wait out its OWN deadline rather than
        // fast-failing near-instantly (contrast with
        // test_aWedgedProbeFailsLaterCallsFastInsteadOfQueueingBehindIt,
        // where a parked .deny call DOES fast-fail every later call).
        let denyStarted = Date()
        do {
            _ = try await gateway.read(service: "s", account: "b", interaction: .deny)
            XCTFail("expected timedOut")
        } catch let error as KeychainGatewayError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(denyStarted), 0.15,
            "a non-wedged gateway must wait out its own deadline, not fail fast like a wedged one"
        )
    }
    /// Finding 2: a wedged gateway (armed by a parked `.deny` probe, exactly
    /// like `test_aWedgedProbeFailsLaterCallsFastInsteadOfQueueingBehindIt`
    /// above) must not ALSO permanently lock out `.allow` — that would
    /// strand the Grant button in precisely the scenario it exists to
    /// recover from. The first `copyMatching` call parks forever (arming
    /// `wedged` via its timeout); the second one answers immediately, so a
    /// real answer proves the `.allow` call reached the escape-hatch queue
    /// rather than being fast-failed like `.deny` correctly is.
    func test_wedgedGatewayStillReachesAllowCallViaEscapeHatch() async throws {
        let callIndex = UncheckedBox<Int>(0)
        let granted = Data("granted".utf8)
        let gateway = KeychainGateway(
            primitives: primitives(copyMatching: { _ in
                var isFirstCall = false
                callIndex.mutate { count in
                    isFirstCall = (count == 0)
                    count += 1
                }
                if isFirstCall {
                    Thread.sleep(forTimeInterval: 30)  // never answers within the test
                    return (errSecSuccess, nil)
                }
                return (errSecSuccess, granted as AnyObject)
            }),
            timeout: 0.2,
            allowTimeout: 5
        )

        // Arm `wedged` via a parked `.deny` probe, same setup as the
        // existing wedge test above.
        _ = try? await gateway.read(service: "s", account: "a", interaction: .deny)

        // A `.deny` call must still fail fast while wedged — unchanged.
        let denyStarted = Date()
        do {
            _ = try await gateway.read(service: "s", account: "b", interaction: .deny)
            XCTFail("expected timedOut")
        } catch let error as KeychainGatewayError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(denyStarted), 0.15,
                          "a wedged gateway must fail a .deny call fast, not wait out its own deadline")

        // An `.allow` call must reach the primitives and get the real
        // second-call answer — NOT an immediate `.timedOut` the way `.deny`
        // correctly gets above, and not stuck waiting out `allowTimeout`
        // either, since the escape-hatch queue is independent of the
        // primary queue's parked closure.
        let started = Date()
        let out = try await gateway.read(service: "s", account: "c", interaction: .allow)
        XCTAssertEqual(out, granted,
                       "a wedged gateway must still let .allow reach a real answer via the escape hatch")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                          "the escape-hatch queue must not be blocked by the parked primary-queue closure")
    }

    /// Closes the wedge-clear boundary race a second review round found in
    /// the escape hatch above: `wedged` clearing and an escape `.allow`
    /// closure finishing are two independent events (the original stuck
    /// probe finally answering has nothing to do with when a human answers
    /// the Grant dialog). The original fix only gated `.deny` on `wedged`,
    /// so a `.deny` call freed by `wedged` clearing could resume on the
    /// primary queue while an escape closure was still draining on
    /// `allowEscapeQueue` — two lanes free to write the shared interaction
    /// flag at once, exactly what the single serial queue exists to
    /// prevent.
    ///
    /// Setup: call 0 (the wedge-arming probe) and call 1 (the Grant escape
    /// call) each block on their own semaphore so the test controls exactly
    /// when each "finally answers." Any further call reaching `copyMatching`
    /// (case `default`) would prove a `.deny` call snuck through while the
    /// escape call was still draining.
    func test_denyFailsFast_whileAnEscapeAllowCallStillDrains_evenAfterWedgeClears() async throws {
        let callIndex = UncheckedBox<Int>(0)
        let probeGate = DispatchSemaphore(value: 0)
        let escapeGate = DispatchSemaphore(value: 0)

        let gateway = KeychainGateway(
            primitives: primitives(copyMatching: { _ in
                var index = -1
                callIndex.mutate { count in
                    index = count
                    count += 1
                }
                switch index {
                case 0:
                    probeGate.wait()  // "the stuck probe finally answers" — test-controlled
                    return (errSecSuccess, nil)
                case 1:
                    escapeGate.wait()  // the still-unanswered Grant dialog
                    return (errSecSuccess, Data("granted".utf8) as AnyObject)
                default:
                    // Must never be reached by a NEW .deny call while
                    // escapeGate is still held — that's the bug.
                    return (errSecSuccess, nil)
                }
            }),
            timeout: 0.2,
            allowTimeout: 5
        )

        // Arm `wedged`. Unlike the other wedge tests, this probe is
        // release-controlled (not parked forever) so the test can later
        // simulate it finally returning.
        _ = try? await gateway.read(service: "s", account: "probe", interaction: .deny)

        // Start the Grant escape call; `wedged` routes it to
        // `allowEscapeQueue`, where it blocks inside `copyMatching`,
        // standing in for an unanswered dialog.
        let escapeTask = Task {
            try? await gateway.read(service: "s", account: "escape", interaction: .allow)
        }

        // Wait for both the probe and the escape call to actually reach
        // copyMatching (and park there) before proceeding.
        let readyDeadline = Date().addingTimeInterval(5.0)
        while Date() < readyDeadline, callIndex.value < 2 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(callIndex.value, 2,
                       "precondition: both the probe and the escape call must have reached copyMatching")

        // Release the original probe — "the stuck probe finally answers,"
        // independent of the still-open Grant dialog. Its queue closure
        // will clear `wedged` once it finishes running.
        probeGate.signal()

        // Across the window where `wedged` transitions from true to false,
        // a NEW `.deny` call must keep failing fast — proving it never
        // resumes on the primary queue while the escape call above is
        // still draining, regardless of which guard (`wedged` or
        // `escapeCallsInFlight`) is currently the one stopping it.
        for _ in 0..<15 {
            let started = Date()
            do {
                _ = try await gateway.read(service: "s", account: "new-deny-\(UUID())", interaction: .deny)
                XCTFail("a .deny call must not succeed while the escape call is still draining")
            } catch let error as KeychainGatewayError {
                XCTAssertEqual(error, .timedOut)
            } catch {
                XCTFail("wrong error type: \(error)")
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.15,
                              "a .deny call must fail fast, not wait out its own deadline, while an escape call is still draining")
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        XCTAssertEqual(callIndex.value, 2,
                       "no .deny call must ever reach copyMatching while the escape call above is still draining")

        // Release the still-parked Grant dialog and let the escape call
        // finish, then confirm the gateway is genuinely usable again — the
        // fix must not turn into a permanent lockout of its own.
        escapeGate.signal()
        _ = await escapeTask.value

        let recoveredStarted = Date()
        _ = try await gateway.read(service: "s", account: "after-recovery", interaction: .deny)
        XCTAssertLessThan(Date().timeIntervalSince(recoveredStarted), 1.0,
                          "once the escape call has finished draining, .deny must work normally again")
    }

    // MARK: - Third adversarial-review round: detection-lag gap for Grant

    /// Half (a): the common, fast case. A `.deny` probe that settles well
    /// within `allowGraceInterval` and an `.allow` call that arrives while
    /// it's still running must NOT get routed to the escape queue — it must
    /// still go through the primary `queue` like every other non-wedged
    /// call. Proven here by timing: if the `.allow` call had been routed to
    /// `allowEscapeQueue` it would run concurrently with the still-parked
    /// `.deny` probe and its own `copyMatching` call would start almost
    /// immediately; if it went through the primary `queue` (serial), its
    /// `copyMatching` call cannot start until the `.deny` probe's closure —
    /// including its own `copyMatching` call — has finished.
    func test_allowArrivingDuringAFastDenyProbe_isNotRoutedToEscapeQueue() async throws {
        struct CallRecord { let index: Int; let start: Date; let end: Date }
        let callIndex = UncheckedBox<Int>(0)
        let records = UncheckedBox<[CallRecord]>([])
        let granted = Data("granted".utf8)

        let gateway = KeychainGateway(
            primitives: primitives(copyMatching: { _ in
                var index = -1
                callIndex.mutate { count in index = count; count += 1 }
                let start = Date()
                if index == 0 {
                    // Stands in for a normal, fast background probe — well
                    // under the grace period below, nowhere near `timeout`.
                    Thread.sleep(forTimeInterval: 0.15)
                }
                let end = Date()
                records.mutate { $0.append(CallRecord(index: index, start: start, end: end)) }
                return (errSecSuccess, granted as AnyObject)
            }),
            timeout: 5,
            allowTimeout: 5,
            allowGraceInterval: 0.5
        )

        async let denyResult: Data? = try? await gateway.read(service: "s", account: "deny", interaction: .deny)
        // Give the .deny probe a moment to actually start running before
        // the .allow call arrives "during it."
        try? await Task.sleep(nanoseconds: 30_000_000)
        async let allowResult: Data? = try? await gateway.read(service: "s", account: "allow", interaction: .allow)

        _ = await denyResult
        let allowOut = await allowResult

        XCTAssertEqual(allowOut, granted, "the .allow call must still reach a real answer")

        let calls = records.value
        XCTAssertEqual(calls.count, 2, "both calls must have reached copyMatching")
        guard let denyCall = calls.first(where: { $0.index == 0 }),
              let allowCall = calls.first(where: { $0.index == 1 }) else {
            return XCTFail("expected exactly two recorded calls")
        }
        XCTAssertGreaterThanOrEqual(
            allowCall.start, denyCall.end,
            "an .allow call arriving during a fast .deny probe must wait for it on the primary queue " +
            "(serialized), not run concurrently on the escape queue — routing it early would reopen " +
            "the interaction-flag trample risk this file's serial design exists to prevent"
        )
    }

    /// Half (b): the actual bug. An `.allow` call arrives after the primary
    /// queue's occupant has been stuck longer than `allowGraceInterval`, but
    /// BEFORE that occupant's own full `timeout` deadline — i.e. before
    /// `wedged` would naturally become true. Before the fix, `run()` only
    /// consulted `wedged`, saw `false`, and queued this call behind the
    /// stuck probe on the primary `queue`, where it would sit uselessly
    /// until its own `allowTimeout` (verified below by disabling the fix).
    /// After the fix, it must reach a real answer promptly via the escape
    /// hatch instead.
    func test_allowArrivingAfterGraceElapsesButBeforeWedgeDeadline_stillReachesRealAnswerViaEscape() async throws {
        let callIndex = UncheckedBox<Int>(0)
        let granted = Data("granted".utf8)
        let gateway = KeychainGateway(
            primitives: primitives(copyMatching: { _ in
                var isFirstCall = false
                callIndex.mutate { count in isFirstCall = (count == 0); count += 1 }
                if isFirstCall {
                    // Stuck for the whole test — nowhere near answering
                    // within `timeout` (5s) either, so `wedged` never fires
                    // during this test.
                    Thread.sleep(forTimeInterval: 30)
                    return (errSecSuccess, nil)
                }
                return (errSecSuccess, granted as AnyObject)
            }),
            timeout: 5,             // the stuck probe's own deadline — long, deliberately not reached
            allowTimeout: 5,
            allowGraceInterval: 0.2  // short grace period
        )

        // Start the stuck .deny probe without awaiting its own (5s) deadline.
        let denyTask = Task { try? await gateway.read(service: "s", account: "stuck", interaction: .deny) }

        // Wait until the probe has actually reached copyMatching (parked).
        let readyDeadline = Date().addingTimeInterval(2.0)
        while Date() < readyDeadline, callIndex.value < 1 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(callIndex.value, 1, "precondition: the probe must have reached copyMatching")

        // Wait past the grace period, but stay well short of `timeout`
        // (5s) — this is the detection-lag window: `wedged` is still false.
        try? await Task.sleep(nanoseconds: 400_000_000)

        let started = Date()
        let out = try await gateway.read(service: "s", account: "grant", interaction: .allow)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(out, granted,
                       "an .allow call arriving during the detection-lag window must still reach a real " +
                       "answer via the escape hatch, not queue behind the stuck probe")
        XCTAssertLessThan(elapsed, 2.0,
                          "must escape promptly — not wait out allowTimeout (5s) queued behind the stuck probe")

        denyTask.cancel()
    }
}

/// Test-local mutable box. The gateway hands its primitives to a background
/// queue, so recorded values need a lock rather than plain capture.
private final class UncheckedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return storage }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&storage); lock.unlock() }
}
