//
//  ProcessLauncherTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class ProcessLauncherTests: XCTestCase {

    /// Verify that `onTermination` fires even when the process exits before
    /// the handler is registered — the pre-terminate race that `markTerminated`
    /// + `hasFired` guards against.
    func test_onTermination_firesImmediatelyWhenProcessAlreadyExited() async throws {
        let launcher = SystemProcessLauncher()
        let handle = try launcher.start(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: nil)

        // Give the process a moment to finish before we register the handler.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(handle.isRunning, "precondition: process must have already exited")

        let exp = expectation(description: "handler fires after process already exited")
        handle.onTermination { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 1)
    }

    /// Verify the common path: handler registered before the process exits.
    func test_onTermination_firesAfterProcessExit() async throws {
        let launcher = SystemProcessLauncher()
        let handle = try launcher.start(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: nil)

        let exp = expectation(description: "handler fires on process exit")
        handle.onTermination { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2)
    }

    /// Verify that the handler fires at most once even if `onTermination` is
    /// called after termination (replace semantics vs double-fire).
    func test_onTermination_doesNotFireTwice() async throws {
        let launcher = SystemProcessLauncher()
        let handle = try launcher.start(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: nil)

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(handle.isRunning, "precondition: process must have already exited")

        var fireCount = 0
        let exp = expectation(description: "handler fires exactly once")
        handle.onTermination {
            fireCount += 1
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1)
        // Brief pause to surface a hypothetical double-fire.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fireCount, 1, "handler must fire exactly once")
    }
}
