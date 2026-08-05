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
