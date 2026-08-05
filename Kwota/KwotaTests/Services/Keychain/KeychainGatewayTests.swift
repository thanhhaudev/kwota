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
        // Release-controlled, not a bare `Thread.sleep` — a cancelled `Task`
        // doesn't interrupt a blocking `Thread.sleep` anyway, so an
        // unreleased sleep would keep this gateway's primary queue
        // genuinely occupied for the full duration after the test returns.
        // Matches the pattern in
        // `test_denyFailsFast_whileAnEscapeAllowCallStillDrains_evenAfterWedgeClears`
        // below: signal the gate before the test ends so nothing outlives it.
        let probeGate = DispatchSemaphore(value: 0)
        let gateway = KeychainGateway(
            primitives: primitives(copyMatching: { _ in
                var isFirstCall = false
                callIndex.mutate { count in isFirstCall = (count == 0); count += 1 }
                if isFirstCall {
                    // Stuck until the test releases it — nowhere near
                    // answering within `timeout` (5s) either, so `wedged`
                    // never fires during this test.
                    probeGate.wait()
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

        // Release the still-parked probe so nothing outlives this test.
        probeGate.signal()
        _ = await denyTask.value
    }

    /// Follow-up review finding on the grace-period mechanism above:
    /// `escapeCallsInFlight`/`wedged` only gate NEW calls entering `run()` —
    /// they don't reach back into a `.deny` closure that was already
    /// admitted onto the primary queue's backlog (dispatched, not yet
    /// running) before either flag went true. Without a re-check at actual
    /// execution time, that already-queued `.deny` closure would still call
    /// `setInteractionAllowed(false)` once its turn came, concurrently with
    /// a still-live escape closure's own flag writes — the exact trample
    /// this file's serial design exists to prevent, and structurally the
    /// original incident's failure mode.
    ///
    /// Setup: A (a `.deny` probe) occupies the primary queue and blocks.
    /// While A is still blocked, B (a second `.deny` call — the one under
    /// test) is admitted normally (nothing is wedged or draining yet) and
    /// queues up BEHIND A on the same serial queue, not yet running. Once A
    /// has been blocked long enough to exceed `allowGraceInterval`, C (an
    /// `.allow` call) arrives; `primaryQueueProbablyStuck()` routes it to
    /// the escape queue, where it also blocks — `escapeCallsInFlight` is
    /// now 1, with B still sitting in the primary queue's backlog. Only
    /// THEN is A released: A's closure finishes, and B finally gets its
    /// turn. B must fail fast with `.timedOut` and must never touch
    /// `setInteractionAllowed` or reach `copyMatching` at all.
    func test_alreadyQueuedDenyFailsFast_whenItsTurnComesWhileAnEscapeCallIsDraining() async throws {
        let callIndex = UncheckedBox<Int>(0)
        let interactionCalls = UncheckedBox<[Bool]>([])
        let probeGateA = DispatchSemaphore(value: 0)
        let escapeGateC = DispatchSemaphore(value: 0)

        let gateway = KeychainGateway(
            primitives: primitives(
                copyMatching: { _ in
                    var index = -1
                    callIndex.mutate { count in index = count; count += 1 }
                    switch index {
                    case 0:
                        probeGateA.wait()  // A: occupies the primary queue
                        return (errSecSuccess, nil)
                    case 1:
                        escapeGateC.wait()  // C: the draining escape call
                        return (errSecSuccess, Data("granted".utf8) as AnyObject)
                    default:
                        // B must never reach here — that's the bug this test guards against.
                        return (errSecSuccess, nil)
                    }
                },
                setInteractionAllowed: { value in interactionCalls.mutate { $0.append(value) } }
            ),
            timeout: 5,
            allowTimeout: 5,
            allowGraceInterval: 0.1
        )

        // A occupies the primary queue and blocks.
        let taskA = Task { try? await gateway.read(service: "s", account: "A", interaction: .deny) }
        var deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, callIndex.value < 1 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(callIndex.value, 1, "precondition: A must be occupying the primary queue")

        // B is admitted while A is still running — normal admission
        // (nothing is wedged or draining yet) — so it queues up BEHIND A
        // on the same serial queue.
        let taskB = Task { try await gateway.read(service: "s", account: "B", interaction: .deny) }
        try? await Task.sleep(nanoseconds: 50_000_000)  // let GCD enqueue B behind A

        // Wait past the grace period so A counts as "probably stuck."
        try? await Task.sleep(nanoseconds: 150_000_000)

        // C (.allow) arrives; `primaryQueueProbablyStuck()` routes it to
        // the escape queue (incrementing `escapeCallsInFlight`), where it
        // blocks in turn.
        let taskC = Task { try? await gateway.read(service: "s", account: "C", interaction: .allow) }
        deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, callIndex.value < 2 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(callIndex.value, 2, "precondition: C must have reached the escape queue and blocked")

        // Release A. B — still queued behind it on the primary queue —
        // gets its turn next, while C is still draining.
        probeGateA.signal()
        _ = await taskA.value

        do {
            _ = try await taskB.value
            XCTFail("expected timedOut")
        } catch let error as KeychainGatewayError {
            XCTAssertEqual(error, .timedOut,
                           "an already-queued .deny call must fail fast, not run, once its turn comes " +
                           "while an escape call is still draining")
        } catch {
            XCTFail("wrong error type: \(error)")
        }

        XCTAssertEqual(callIndex.value, 2,
                       "B must never reach copyMatching — it must fail before touching the primitives at all")

        // Release C and let it finish. A contributed 2 setInteractionAllowed
        // calls ([false, true]); C contributes its own 2. If B had
        // incorrectly run, it would have contributed a third pair —
        // asserting exactly 4 total proves B never touched the flag.
        escapeGateC.signal()
        _ = await taskC.value

        XCTAssertEqual(interactionCalls.value.count, 4,
                       "only A's and C's own setInteractionAllowed calls must exist — B must never have called it")
    }

    /// Follow-up review finding on the bail path just added above: bailing
    /// with `resume(throwing: .timedOut)` closed the trample hazard, but
    /// did so WITHOUT running `clearsWedgeOnCompletion` — every OTHER
    /// primary-queue closure (bail or normal completion) is what proves
    /// `wedged` is stale enough to clear; a bail that skips that step
    /// breaks the invariant "every primary-queue closure eventually clears
    /// `wedged`," which can strand it `true` forever if a genuinely stale
    /// `wedged` (armed by some other call's deadline, moments earlier) is
    /// what triggered this bail and nothing else ever runs again to clear
    /// it. This test drives a real bail while `wedged` has genuinely been
    /// armed for real (via A's own short `timeout` firing while A is still
    /// blocked) and confirms the gateway fully recovers afterward — a
    /// fresh, unrelated `.deny` call succeeds normally and quickly, not
    /// fast-failing forever.
    ///
    /// Honest limitation, documented per this file's own established
    /// practice: this test cannot force B's OWN re-check to observe
    /// `wedged == true` at the exact instant it runs. Every primary-queue
    /// closure directly ahead of B — whether it completes normally or
    /// bails — unconditionally clears `wedged` (when eligible) as the very
    /// last synchronous step before the queue can advance to B; GCD only
    /// dequeues the next block after the current one fully returns. So the
    /// only way for B to observe a stale `wedged == true` is a genuine race
    /// between an independent call's deadline timer and that handoff — a
    /// window on the order of the OS's own block-to-block dequeue latency,
    /// not something forceable via test sequencing (matches the reviewer's
    /// own characterization: "microseconds to low milliseconds"). What
    /// this test DOES verify deterministically: `wedged` genuinely engages
    /// for real during the test (A's own timeout fires while blocked), a
    /// bail genuinely occurs on the same gateway (B, via
    /// `escapeCallsInFlight`, exercising the exact shared bail body the
    /// fix changed — the same `if clearsWedgeOnCompletion { wedged = false }`
    /// line applies unconditionally whichever condition triggered entry),
    /// and the gateway is fully healthy afterward. Source-level: the fix's
    /// clear is unconditional within the bail branch regardless of which
    /// of `isWedgedNow`/`hasDrainingEscapeCallsNow` was true, so this test
    /// exercising the branch via one condition still exercises the exact
    /// line that protects against the other.
    func test_bailPathDoesNotStrandWedged_gatewayRecoversForSubsequentCalls() async throws {
        let callIndex = UncheckedBox<Int>(0)
        let probeGateA = DispatchSemaphore(value: 0)
        let escapeGateC = DispatchSemaphore(value: 0)
        let recovered = Data("recovered".utf8)

        let gateway = KeychainGateway(
            primitives: primitives(copyMatching: { _ in
                var index = -1
                callIndex.mutate { count in index = count; count += 1 }
                switch index {
                case 0:
                    probeGateA.wait()  // A: genuinely wedges — its own short timeout fires while blocked
                    return (errSecSuccess, nil)
                case 1:
                    escapeGateC.wait()  // C: the draining escape call
                    return (errSecSuccess, Data("granted".utf8) as AnyObject)
                case 2:
                    return (errSecSuccess, recovered as AnyObject)  // the follow-up call, after everything settles
                default:
                    // B must never reach here — that's the earlier bug this file already guards against.
                    return (errSecSuccess, nil)
                }
            }),
            timeout: 0.15,            // SHORT — A will genuinely hit `wedged = true` while still blocked
            allowTimeout: 5,
            allowGraceInterval: 0.1
        )

        // A occupies the primary queue and blocks.
        let taskA = Task { try? await gateway.read(service: "s", account: "A", interaction: .deny) }
        var deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, callIndex.value < 1 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(callIndex.value, 1, "precondition: A must be occupying the primary queue")

        // B is admitted while A is still running — queues up behind A.
        let taskB = Task { try await gateway.read(service: "s", account: "B", interaction: .deny) }
        try? await Task.sleep(nanoseconds: 50_000_000)  // let GCD enqueue B behind A

        // Wait past A's own `timeout` (0.15s) — A genuinely wedges: its
        // deadline timer fires while it's still blocked, setting
        // `wedged = true` for real (not synthetically).
        try? await Task.sleep(nanoseconds: 300_000_000)

        // C (.allow) arrives; A has also exceeded `allowGraceInterval` by
        // now, so C routes to the escape queue and blocks there —
        // `escapeCallsInFlight` becomes 1.
        let taskC = Task { try? await gateway.read(service: "s", account: "C", interaction: .allow) }
        deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, callIndex.value < 2 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(callIndex.value, 2, "precondition: C must have reached the escape queue and blocked")

        // Release A. Its own completion clears `wedged` (existing,
        // unchanged behavior) — B, still queued behind it, gets its turn
        // next while C is still draining, and bails via the shared bail
        // branch this fix touched.
        probeGateA.signal()
        _ = await taskA.value

        // `taskA.value`/`taskB.value` can resolve EARLY via their own
        // short `timeout` (0.15s) deadline timers — decoupled from when
        // their REAL closures actually run on `queue`, since a timer firing
        // only means the `async` caller gave up, not that the underlying
        // GCD closure has progressed. Give the real queue processing (A's
        // real completion, then B's real bail-check) genuine wall-clock
        // margin to happen before checking B's outcome or releasing
        // `escapeGateC` — without this, the test can race ahead of B's real
        // closure actually observing `escapeCallsInFlight`, making it
        // flaky/misleading rather than a reliable regression check.
        try? await Task.sleep(nanoseconds: 200_000_000)

        do {
            _ = try await taskB.value
            XCTFail("expected timedOut")
        } catch let error as KeychainGatewayError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertEqual(callIndex.value, 2, "B must never reach copyMatching")

        // Release C and let it finish.
        escapeGateC.signal()
        _ = await taskC.value

        // The actual regression: confirm neither A's real wedge-and-clear
        // cycle nor B's bail left `wedged` stranded — a fresh, unrelated
        // `.deny` call on the now-idle gateway must succeed normally and
        // quickly, not fail fast forever.
        let recoveredStart = Date()
        let out = try await gateway.read(service: "s", account: "after", interaction: .deny)
        XCTAssertEqual(out, recovered,
                       "the gateway must be fully usable again after the bail — wedged must not be left stranded")
        XCTAssertLessThan(Date().timeIntervalSince(recoveredStart), 1.0,
                          "a healthy gateway must answer quickly, not fail fast forever from a stranded wedged flag")
    }

    // MARK: - A third adversarial-review round (round 6): stale deadline still ran work()

    /// Finding 1: every call's own deadline timer is armed the instant
    /// `enqueue(...)` is called, independent of whether that call has
    /// actually started running yet — it can still be sitting in `queue`'s
    /// FIFO backlog behind a slow-but-not-permanently-stuck occupant. If
    /// the deadline fires while queued, the caller already receives
    /// `.timedOut` — but before this fix, `work()` still ran
    /// UNCONDITIONALLY once the call's turn finally came, silently
    /// mutating the real Keychain long after the caller gave up (for a
    /// write, potentially clobbering a NEWER write from a subsequent
    /// successful retry with STALE data).
    ///
    /// Setup: A occupies the primary queue and blocks (release-controlled).
    /// B is admitted right behind A on the same serial queue — normal
    /// admission, nothing wedged yet. Both A and B share the same short
    /// `timeout`; A is held blocked well past BOTH of their own deadlines,
    /// so each fires independently via its own timer while B is still
    /// sitting in the backlog, never having started. A's OWN deadline
    /// firing sets `wedged = true` — but A's own eventual completion
    /// (once released) unconditionally CLEARS `wedged` again, as the very
    /// last thing before the queue advances to B. So by the time B's
    /// closure actually starts, `wedged` is back to `false` — round 4's
    /// `.deny` re-check (which only fires while `wedged`/draining) does
    /// NOT catch this; only Finding 1's peek does. `copyMatching` must
    /// never be called a second time.
    func test_deadlineFiredWhileStillQueued_doesNotRunWorkAfterCallerAlreadyGaveUp() async throws {
        let callIndex = UncheckedBox<Int>(0)
        let probeGateA = DispatchSemaphore(value: 0)

        let gateway = KeychainGateway(
            primitives: primitives(copyMatching: { _ in
                var index = -1
                callIndex.mutate { count in index = count; count += 1 }
                if index == 0 {
                    probeGateA.wait()  // A: occupies the primary queue, release-controlled
                    return (errSecSuccess, nil)
                }
                if index == 1 {
                    // The legitimate final health-check call at the bottom
                    // of the test, reached only once B has (correctly)
                    // never called copyMatching at all.
                    return (errSecItemNotFound, nil)
                }
                // index >= 2: B incorrectly reached copyMatching — that's
                // the bug. Returns immediately (doesn't block) so a
                // pre-fix regression fails via assertion below instead of
                // hanging the test.
                return (errSecSuccess, Data("ran-after-caller-already-gave-up".utf8) as AnyObject)
            }),
            timeout: 0.2,
            allowTimeout: 5
        )

        // A occupies the primary queue and blocks.
        let taskA = Task { try await gateway.read(service: "s", account: "A", interaction: .deny) }
        var deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, callIndex.value < 1 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(callIndex.value, 1, "precondition: A must be occupying the primary queue")

        // B is admitted right after A — normal admission (nothing wedged
        // yet) — so it queues up BEHIND A on the same serial queue, not
        // yet running.
        let taskB = Task { try await gateway.read(service: "s", account: "B", interaction: .deny) }
        try? await Task.sleep(nanoseconds: 30_000_000)  // let GCD enqueue B behind A

        // Wait past BOTH A's and B's own `timeout` (0.2s) while A is STILL
        // blocked — each call's own deadline timer fires independently of
        // whether its closure has started running. A's firing sets
        // `wedged = true` (it's `.deny`).
        try? await Task.sleep(nanoseconds: 350_000_000)

        // Both callers must already have their answer via the timer path —
        // proving neither is waiting on its closure to actually run.
        do {
            _ = try await taskA.value
            XCTFail("expected timedOut")
        } catch let error as KeychainGatewayError {
            XCTAssertEqual(error, .timedOut, "A's own deadline must fire while it's still blocked")
        }
        do {
            _ = try await taskB.value
            XCTFail("expected timedOut")
        } catch let error as KeychainGatewayError {
            XCTAssertEqual(error, .timedOut, "B's own deadline must fire while it's still queued behind A")
        }

        // Release A now. A's own completion clears `wedged` (it's what set
        // it) as the very last synchronous step before the queue can
        // advance to B — so B's turn arrives with `wedged == false`,
        // meaning round 4's re-check does not catch this; only the new
        // peek does.
        probeGateA.signal()

        // Give the real queue processing (A's real completion, then B's
        // real turn) genuine wall-clock margin — `taskA.value`/`taskB.value`
        // above already resolved via their OWN deadline timers, decoupled
        // from when their real GCD closures actually run.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(callIndex.value, 1,
                       "B must never reach copyMatching — its own deadline already fired while it was " +
                       "still queued behind A, so running work() now would silently mutate the real " +
                       "Keychain long after the caller already gave up")

        // Confirm the gateway is genuinely healthy afterward too.
        let recoveredStart = Date()
        let out = try await gateway.read(service: "s", account: "after", interaction: .deny)
        XCTAssertNil(out, "the stub returns errSecItemNotFound by default for any further, genuinely-run call")
        XCTAssertLessThan(Date().timeIntervalSince(recoveredStart), 1.0,
                          "gateway must be fully usable again — nothing stranded by the fix")
    }

    // MARK: - Round 6: admission-race gap in the .allow routing decision

    /// Finding 2: `run(interaction:_:)`'s `.allow` routing decision has a
    /// check-then-enqueue race. It snapshots state synchronously, then
    /// `await`s `primaryQueueProbablyStuck()` — a genuine suspension point.
    /// A completely different `.deny` call can be admitted onto the
    /// primary queue and become its new occupant during that suspension —
    /// one the check never evaluated, because it didn't exist yet.
    /// Without a fix, the `.allow` call proceeds onto the primary queue
    /// trusting a stale "looked safe" answer and lands behind this fresh,
    /// undetected occupant with no escape route — right back to waiting
    /// out the full `allowTimeout` uselessly.
    ///
    /// Setup: A (`.deny`) occupies the primary queue and blocks. C
    /// (`.allow`) arrives while A is still within its grace period — its
    /// `primaryQueueProbablyStuck()` check goes into the real
    /// continuation-wait. While C is suspended there, B (`.deny`) is
    /// admitted — queues up BEHIND A on the same serial queue (this is the
    /// admission race: it happens entirely within C's suspension window).
    /// A is then released BEFORE the grace period elapses, which resolves
    /// C's first check with "not stuck" (stale — A cleared, but says
    /// nothing about B) AND lets GCD dequeue B next, which blocks in its
    /// own right — the fresh, undetected occupant. The fix must catch this
    /// via the admission-generation re-check and route C to the escape
    /// queue after confirming B looks stuck too, rather than let C land
    /// behind B.
    func test_allowRoutingRace_freshOccupantAdmittedDuringPrimaryQueueProbablyStuckSuspension_stillEscapes() async throws {
        let callIndex = UncheckedBox<Int>(0)
        let probeGateA = DispatchSemaphore(value: 0)
        let probeGateB = DispatchSemaphore(value: 0)
        let granted = Data("granted-for-C".utf8)

        let gateway = KeychainGateway(
            primitives: primitives(copyMatching: { _ in
                var index = -1
                callIndex.mutate { count in index = count; count += 1 }
                switch index {
                case 0:
                    probeGateA.wait()  // A: occupies the primary queue first
                    return (errSecSuccess, nil)
                case 1:
                    probeGateB.wait()  // B: the fresh occupant admitted during C's suspension
                    return (errSecSuccess, nil)
                case 2:
                    return (errSecSuccess, granted as AnyObject)  // C: reached via the escape queue
                default:
                    return (errSecSuccess, nil)
                }
            }),
            timeout: 5,              // A/B's own deadline — long, deliberately not reached
            allowTimeout: 5,         // C's own deadline — long; must escape well before this
            allowGraceInterval: 0.2
        )

        // A occupies the primary queue and blocks.
        let taskA = Task { try? await gateway.read(service: "s", account: "A", interaction: .deny) }
        var deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, callIndex.value < 1 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(callIndex.value, 1, "precondition: A must be occupying the primary queue")

        // C (.allow) arrives while A occupies the queue and hasn't
        // exceeded grace yet — its `primaryQueueProbablyStuck()` check
        // goes into the real continuation-wait.
        let taskC = Task { try await gateway.read(service: "s", account: "C", interaction: .allow) }
        // Give C's task time to actually reach that suspension before B
        // shows up.
        try? await Task.sleep(nanoseconds: 60_000_000)

        // B is admitted while A is still running — normal admission — so
        // it queues up BEHIND A on the primary queue, not yet running.
        // This is the admission that races with C's still-pending "is the
        // primary queue safe" decision. `run()`'s generation bump for B
        // happens synchronously here, well before A is released below —
        // making the eventual generation check deterministic regardless of
        // exact thread scheduling later on.
        let taskB = Task { try? await gateway.read(service: "s", account: "B", interaction: .deny) }
        try? await Task.sleep(nanoseconds: 60_000_000)  // let GCD enqueue B behind A

        // Release A — BEFORE the grace period elapses, so C's first
        // `primaryQueueProbablyStuck()` resolves "not stuck" via the
        // "occupant cleared in time" waiter path (stale: says nothing
        // about B, which is about to start running next).
        probeGateA.signal()
        _ = await taskA.value

        // B, queued behind A, gets its turn next and blocks in its own
        // right — the fresh, undetected occupant.
        deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, callIndex.value < 2 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(callIndex.value, 2, "precondition: B must now be occupying the primary queue")

        // C must still reach a real answer via the escape queue, promptly
        // — not land behind B and wait out the full allowTimeout (5s).
        let started = Date()
        let outC = try await taskC.value
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(outC, granted,
                       "C must escape to a real answer rather than land behind the fresh, undetected occupant B")
        XCTAssertLessThan(elapsed, 2.0,
                          "must escape promptly (bounded by ~2x allowGraceInterval plus the settle delay), " +
                          "not wait out allowTimeout queued behind B")

        // Release B and confirm the gateway is healthy afterward.
        probeGateB.signal()
        _ = await taskB.value

        let recoveredStart = Date()
        _ = try await gateway.read(service: "s", account: "after", interaction: .deny)
        XCTAssertLessThan(Date().timeIntervalSince(recoveredStart), 1.0,
                          "gateway must be fully usable again after the race resolves")
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
