//
//  CLIProcessRunner.swift
//  Kwota
//
//  Shared subprocess plumbing for the headless agent-CLI runners
//  (`ClaudeCLIRunner`, `CodexCLIRunner`): incremental pipe draining,
//  timeout watchdog with SIGTERM→SIGKILL escalation, and typed
//  cancellation. Extracted from `ClaudeCLIRunner` so both runners share
//  one battle-tested implementation.
//

import Foundation

enum CLIProcess {
    /// Launch `binary` with `args`, optionally feeding `stdin`, drain both
    /// pipes, enforce `timeout`. Returns raw stdout/stderr bytes plus the
    /// exit status — interpreting the bytes is the caller's job.
    ///
    /// `currentDirectory` defaults to the system temp dir so a CLI's
    /// project auto-discovery (CLAUDE.md, AGENTS.md, git repo) can't pick
    /// up whatever project the host app happened to launch from.
    ///
    /// `environment` overrides the child's process environment when non-nil.
    /// When nil (default), the child inherits the parent's environment
    /// unchanged. Pass a value to augment PATH for node-shebang CLIs whose
    /// runtime may not be on the Finder-launched app's minimal PATH.
    ///
    /// If the caller's `Task` is cancelled, the child process is
    /// terminated (SIGTERM + SIGKILL after 1 s) and the continuation
    /// throws `CLIInvocationError.cancelled`.
    static func run(
        binary: String,
        args: [String],
        stdin: Data? = nil,                                          // DELTA
        currentDirectory: URL = FileManager.default.temporaryDirectory, // DELTA
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) async throws -> (stdout: Data, stderr: Data, exitCode: Int32) {
        // Shared slot for the spawned Process so the cancellation handler can
        // reach it. Written once from the background queue that sets up the
        // process; read from the cancellation handler (any thread).
        let processLock = NSLock()
        var capturedProcess: Process?

        // Cancellation flag — onCancel sets this so the termination handler
        // (which races onCancel) emits `.cancelled` instead of `.success`
        // with the SIGTERM exit code. Without it the caller sees
        // `.nonZeroExit(status: -15)` for what should be a typed cancel.
        let cancelLock = NSLock()
        var wasCancelled = false

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // Run the Process on a background queue so we never block the
                // caller's actor (typically MainActor) on subprocess setup.
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: binary)
                    process.arguments = args
                    process.currentDirectoryURL = currentDirectory   // DELTA
                    if let environment {
                        process.environment = environment
                    }

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    // DELTA: optional stdin. The pipe must be wired before
                    // run(); the data is written after launch (cache-eval
                    // prompts are a few KB — far below the 64 KB pipe
                    // buffer, so a synchronous write can't deadlock).
                    let stdinPipe: Pipe?
                    if stdin != nil {
                        let pipe = Pipe()
                        process.standardInput = pipe
                        stdinPipe = pipe
                    } else {
                        stdinPipe = nil
                    }

                    // Drain pipes incrementally so a chatty CLI can't deadlock
                    // by filling its stdout buffer before we read.
                    let dataLock = NSLock()
                    var stdoutData = Data()
                    var stderrData = Data()
                    stdout.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { return }
                        dataLock.lock()
                        stdoutData.append(chunk)
                        dataLock.unlock()
                    }
                    stderr.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { return }
                        dataLock.lock()
                        stderrData.append(chunk)
                        dataLock.unlock()
                    }

                    // Resume the continuation exactly once — termination
                    // handler, timeout, and cancellation race; whichever wins
                    // owns the resume.
                    let resumeLock = NSLock()
                    var didResume = false
                    func resumeOnce(_ result: Result<(stdout: Data, stderr: Data, exitCode: Int32), Error>) {
                        resumeLock.lock()
                        defer { resumeLock.unlock() }
                        guard !didResume else { return }
                        didResume = true
                        cont.resume(with: result)
                    }

                    process.terminationHandler = { proc in
                        stdout.fileHandleForReading.readabilityHandler = nil
                        stderr.fileHandleForReading.readabilityHandler = nil

                        // Drain any final bytes still in the pipe — a partial
                        // chunk may have landed between the last fire and detach.
                        if let final = try? stdout.fileHandleForReading.readToEnd() {
                            dataLock.lock(); stdoutData.append(final); dataLock.unlock()
                        }
                        if let final = try? stderr.fileHandleForReading.readToEnd() {
                            dataLock.lock(); stderrData.append(final); dataLock.unlock()
                        }

                        dataLock.lock()
                        let out = stdoutData
                        let err = stderrData
                        dataLock.unlock()

                        cancelLock.lock()
                        let cancelled = wasCancelled
                        cancelLock.unlock()
                        if cancelled {
                            resumeOnce(.failure(CLIInvocationError.cancelled))
                        } else {
                            resumeOnce(.success((out, err, proc.terminationStatus)))
                        }
                    }

                    do {
                        try process.run()
                    } catch {
                        resumeOnce(.failure(CLIInvocationError.launchFailed(String(describing: error))))
                        return
                    }

                    // DELTA: feed stdin after launch, then close so the CLI
                    // sees EOF and starts processing.
                    if let stdin, let stdinPipe {
                        stdinPipe.fileHandleForWriting.write(stdin)
                        try? stdinPipe.fileHandleForWriting.close()
                    }

                    // Publish the process so the cancellation handler can reach
                    // it. Lock the write so a cancellation that fires between
                    // alloc and here doesn't miss; the onCancel handler will
                    // terminate as soon as it can read capturedProcess.
                    processLock.lock()
                    capturedProcess = process
                    processLock.unlock()

                    // Timeout watchdog. Terminating mid-run triggers the
                    // terminationHandler, but we beat it to the resume so the
                    // caller sees `.timeout` instead of a confusing SIGTERM exit.
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        guard process.isRunning else { return }
                        process.terminate()                  // SIGTERM first
                        resumeOnce(.failure(CLIInvocationError.timeout))

                        // Give the child 1 second to honor SIGTERM, then SIGKILL.
                        // Both CLIs are well-behaved Node/Rust and respond to
                        // SIGTERM in practice; the escalation guards against a
                        // future hang.
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                            if process.isRunning {
                                kill(process.processIdentifier, SIGKILL)
                            }
                        }
                    }
                }
            }
        } onCancel: {
            // Called on any thread when the enclosing Task is cancelled.
            // Set the cancel flag BEFORE terminating so the terminationHandler
            // (which will fire as a result of terminate()) sees it and
            // resumes with `.cancelled` instead of treating SIGTERM as a
            // plain non-zero exit.
            cancelLock.lock()
            wasCancelled = true
            cancelLock.unlock()
            processLock.lock()
            let proc = capturedProcess
            processLock.unlock()
            proc?.terminate()
            // SIGKILL escalation matches the timeout path's 1 s grace.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                if proc?.isRunning == true {
                    kill(proc!.processIdentifier, SIGKILL)
                }
            }
        }
    }
}
