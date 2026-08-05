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
