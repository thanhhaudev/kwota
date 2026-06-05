//
//  MockProcessLauncher.swift
//  KwotaTests
//

import Foundation
@testable import Kwota

final class MockProcessLauncher: ProcessLauncher {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]?
    }

    var runResult: ProcessResult = ProcessResult(stdout: "", stderr: "", exitCode: 0)
    var startError: Error?
    /// Always points to the most recently returned handle, matching caller expectations.
    private(set) var startHandle: MockProcessHandle = MockProcessHandle()
    private(set) var invocations: [Invocation] = []

    func run(executable: String, arguments: [String], environment: [String: String]?) throws -> ProcessResult {
        invocations.append(.init(executable: executable, arguments: arguments, environment: environment))
        return runResult
    }

    func start(executable: String, arguments: [String], environment: [String: String]?) throws -> ProcessHandle {
        if let startError { throw startError }
        invocations.append(.init(executable: executable, arguments: arguments, environment: environment))
        // Create a fresh handle per launch so the identity guard in
        // CaffeinateManager correctly distinguishes separate processes.
        let handle = MockProcessHandle()
        handle.isRunning = true
        startHandle = handle
        return handle
    }
}

final class MockProcessHandle: ProcessHandle {
    var isRunning: Bool = false
    private(set) var terminateCount = 0
    private var handler: (@MainActor () -> Void)?

    func terminate() {
        terminateCount += 1
        isRunning = false
        // terminate() also fires terminationHandler in real Process — mirror that.
        invokeHandler()
    }

    func onTermination(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    /// Test helper: pretend the child exited on its own (e.g. `caffeinate -t` timer fired).
    @MainActor
    func simulateExit() {
        isRunning = false
        invokeHandler()
    }

    private func invokeHandler() {
        guard let h = handler else { return }
        Task { @MainActor in h() }
    }
}
