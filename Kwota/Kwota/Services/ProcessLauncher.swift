//
//  ProcessLauncher.swift
//  Kwota
//

import Foundation

struct ProcessResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

protocol ProcessLauncher {
    func run(executable: String, arguments: [String], environment: [String: String]?) throws -> ProcessResult
    func start(executable: String, arguments: [String], environment: [String: String]?) throws -> ProcessHandle
}

protocol ProcessHandle: AnyObject {
    var isRunning: Bool { get }
    func terminate()
    /// Register a handler invoked at most once when the child process exits
    /// for any reason (normal exit, signal, terminate()). Implementations must
    /// dispatch to `@MainActor` before calling the handler; CaffeinateManager
    /// assumes it can mutate state synchronously inside the callback. Calling
    /// `onTermination` more than once replaces the previous handler.
    func onTermination(_ handler: @escaping @MainActor () -> Void)
}

final class SystemProcessLauncher: ProcessLauncher {
    func run(executable: String, arguments: [String], environment: [String: String]?) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let outRead = PipeRead()
        let errRead = PipeRead()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outRead.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errRead.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        process.waitUntilExit()
        readGroup.wait()
        let outData = outRead.data
        let errData = errRead.data

        return ProcessResult(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    func start(executable: String, arguments: [String], environment: [String: String]?) throws -> ProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        try process.run()
        return SystemProcessHandle(process: process)
    }
}

private final class PipeRead: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }
}

private final class SystemProcessHandle: ProcessHandle {
    private let process: Process
    private let lock = NSLock()
    // All three guarded by `lock`.
    private var handler: (@MainActor () -> Void)?
    private var hasTerminated = false
    private var hasFired = false

    init(process: Process) {
        self.process = process
        process.terminationHandler = { [weak self] _ in
            // Process.terminationHandler runs on an arbitrary queue. Hop
            // to MainActor so callers can mutate UI-bound state safely.
            self?.markTerminated()
        }
    }

    var isRunning: Bool { process.isRunning }
    func terminate() { if process.isRunning { process.terminate() } }

    func onTermination(_ handler: @escaping @MainActor () -> Void) {
        let toFire: (@MainActor () -> Void)?
        lock.lock()
        self.handler = handler
        if hasTerminated && !hasFired {
            hasFired = true
            toFire = handler
        } else {
            toFire = nil
        }
        lock.unlock()
        if let toFire {
            Task { @MainActor in toFire() }
        }
    }

    /// Called from `Process.terminationHandler` on an arbitrary queue.
    /// If a handler has already been registered via `onTermination`, fires
    /// it. Otherwise sets `hasTerminated` so a future `onTermination` call
    /// fires the handler immediately.
    private func markTerminated() {
        let toFire: (@MainActor () -> Void)?
        lock.lock()
        hasTerminated = true
        if let h = handler, !hasFired {
            hasFired = true
            toFire = h
        } else {
            toFire = nil
        }
        lock.unlock()
        if let toFire {
            Task { @MainActor in toFire() }
        }
    }
}
