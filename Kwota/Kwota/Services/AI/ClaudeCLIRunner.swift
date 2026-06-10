//
//  ClaudeCLIRunner.swift
//  Kwota
//
//  Spawns Claude Code's `claude` CLI in headless mode (`-p`) to run a
//  one-shot prompt. Cache AI evaluation uses this instead of calling
//  Anthropic's `/v1/messages` directly because Anthropic gates third-party
//  OAuth-Bearer use of the messages endpoint — the user's CLI token works
//  from `claude` itself but is refused from Kwota's process. Going through
//  the CLI inherits Claude Code's trusted client identity at the cost of
//  consuming the user's normal quota.
//
//  Invocation shape:
//
//      claude -p <userPrompt> --system-prompt <systemPrompt>
//             --model <model> --output-format json --json-schema <schema>
//             --disable-slash-commands --strict-mcp-config --tools ""
//             --setting-sources project
//
//  `--output-format json` wraps the run in an envelope; `--json-schema`
//  forces the model's answer into the `structured_output` field of that
//  envelope, so we get validated structured data instead of scraping JSON
//  out of free text. The trailing four flags isolate the run from the
//  user's local Claude Code environment (skills, MCP servers, tools,
//  hooks) — see `ask(...)` for the rationale. `--bare` is deliberately
//  NOT used: it skips keychain reads and demands an API key, which would
//  defeat the whole point of routing through the user's logged-in CLI
//  session.
//

import Foundation

/// Headless invocation of the Claude Code CLI.
protocol ClaudeCLIInvocation: Sendable {
    /// Runs `claude -p` headless and returns the model's answer as a JSON
    /// string. When `jsonSchema` is non-nil the returned string is the
    /// CLI's `structured_output` object (guaranteed to match the schema);
    /// when nil it's the plain `result` text. Throws
    /// `ClaudeCLIRunner.InvocationError` on any failure.
    func ask(
        systemPrompt: String,
        userPrompt: String,
        model: String?,
        jsonSchema: String?,
        timeout: TimeInterval
    ) async throws -> String
}

final class ClaudeCLIRunner: ClaudeCLIInvocation {
    /// Failure modes the cache evaluator wants to distinguish in the UI.
    enum InvocationError: Error, Equatable {
        /// `claude` binary not found in any candidate location.
        case notInstalled
        /// `Process.run()` itself threw before the CLI started.
        case launchFailed(String)
        /// Process exited non-zero and stdout wasn't a parseable envelope.
        case nonZeroExit(status: Int32, message: String)
        /// The CLI ran but its JSON envelope reported `is_error: true`
        /// (auth failure, quota, etc.) — carries the envelope's message.
        case cliReportedError(String)
        /// Envelope couldn't be parsed, or `structured_output` was missing
        /// when a schema was requested.
        case malformedOutput(String)
        /// Process took longer than the configured timeout.
        case timeout
        /// The caller's Task was cancelled; the child process has been
        /// terminated (SIGTERM + SIGKILL escalation after 1 s).
        case cancelled
    }

    /// Candidate locations to probe for the `claude` binary, in priority
    /// order. Covers the install footprints we see in the wild:
    /// Anthropic's installer (`~/.local/bin`), npm globals
    /// (`~/.npm-global/bin`), Homebrew (`/opt/homebrew/bin`,
    /// `/usr/local/bin`). NSTask doesn't inherit the user's interactive
    /// shell PATH so we can't rely on `which` from inside Kwota — explicit
    /// candidate list is the simplest robust answer.
    static let candidatePaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    }()

    private let resolveBinary: @Sendable () -> String?

    init(resolveBinary: @escaping @Sendable () -> String? = ClaudeCLIRunner.defaultBinaryResolver) {
        self.resolveBinary = resolveBinary
    }

    /// First candidate path that is executable, or nil if none match. Tests
    /// inject their own resolver to bypass disk probing.
    static let defaultBinaryResolver: @Sendable () -> String? = {
        let fm = FileManager.default
        for path in candidatePaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    func ask(
        systemPrompt: String,
        userPrompt: String,
        model: String?,
        jsonSchema: String?,
        timeout: TimeInterval
    ) async throws -> String {
        guard let binary = resolveBinary() else {
            throw InvocationError.notInstalled
        }

        // Environment-isolation flags. `--bare` would do all of this in
        // one shot but also disables keychain reads → no OAuth, so we
        // strip the local Claude Code environment piecemeal instead:
        //   --disable-slash-commands  no skills
        //   --strict-mcp-config       no MCP servers (no --mcp-config given)
        //   --tools ""                no tools → deterministic one-shot,
        //                             and no PreToolUse hooks can fire
        //   --setting-sources project only project-scoped settings; the
        //                             neutral temp cwd has none, so the
        //                             user's hooks never load
        // This keeps the evaluation reproducible and cuts ~94% of the
        // cached-context tokens the user would otherwise be billed for.
        var args = [
            "-p", userPrompt,
            "--system-prompt", systemPrompt,
            "--output-format", "json",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--tools", "",
            "--setting-sources", "project",
        ]
        if let model {
            args.append(contentsOf: ["--model", model])
        }
        if let jsonSchema {
            args.append(contentsOf: ["--json-schema", jsonSchema])
        }
        let schemaUsed = jsonSchema != nil

        let (stdoutData, stderrData, exitCode) = try await runProcess(
            binary: binary,
            args: args,
            timeout: timeout
        )
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch Self.interpretResult(
            stdout: stdoutData,
            stderr: stderr,
            exitCode: exitCode,
            jsonSchemaUsed: schemaUsed
        ) {
        case .success(let text): return text
        case .failure(let err): throw err
        }
    }

    /// Decode the `--output-format json` envelope into either the model's
    /// answer or a typed error. Pure + static so tests can exercise every
    /// branch (auth failure, missing `structured_output`, non-JSON stdout)
    /// without spawning a subprocess.
    ///
    /// Envelope shape (observed from `claude … --output-format json`):
    /// ```
    /// {"type":"result","subtype":"success","is_error":false,
    ///  "result":"<chatter>","structured_output":{…}, …}
    /// ```
    static func interpretResult(
        stdout: Data,
        stderr: String,
        exitCode: Int32,
        jsonSchemaUsed: Bool
    ) -> Result<String, InvocationError> {
        guard
            let root = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any]
        else {
            // No parseable envelope. A non-zero exit here is a hard
            // failure (binary missing a subcommand, crash); exit 0 with
            // garbage stdout shouldn't happen but we treat it the same.
            let detail = stderr.isEmpty
                ? "no JSON envelope on stdout"
                : stderr
            if exitCode != 0 {
                return .failure(.nonZeroExit(status: exitCode, message: detail))
            }
            return .failure(.malformedOutput(detail))
        }

        let isError = root["is_error"] as? Bool ?? false
        let resultText = (root["result"] as? String) ?? ""
        if isError {
            return .failure(.cliReportedError(
                resultText.isEmpty ? "(CLI reported an error with no message)" : resultText
            ))
        }

        guard jsonSchemaUsed else {
            return .success(resultText)
        }

        // Schema was requested → the validated answer lives in
        // `structured_output`. Re-serialize that sub-object so the caller
        // gets a clean JSON string to decode against its own type.
        guard let structured = root["structured_output"] else {
            return .failure(.malformedOutput("envelope missing structured_output"))
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: structured),
            let json = String(data: data, encoding: .utf8)
        else {
            return .failure(.malformedOutput("structured_output not re-serializable"))
        }
        return .success(json)
    }

    // MARK: - Process plumbing

    /// Launch `binary` with `args`, drain both pipes, enforce `timeout`.
    /// Returns raw stdout/stderr bytes plus the exit status. Interpreting
    /// the bytes is the caller's job (`interpretResult`).
    ///
    /// If the caller's `Task` is cancelled, the child process is terminated
    /// (SIGTERM + SIGKILL after 1 s) and the continuation throws
    /// `InvocationError.cancelled`.
    private func runProcess(
        binary: String,
        args: [String],
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
                    // Neutral cwd so the CLI's CLAUDE.md auto-discovery can't
                    // pick up whatever project the host app happened to launch
                    // from and inject it into the prompt.
                    process.currentDirectoryURL = FileManager.default.temporaryDirectory

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

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
                            resumeOnce(.failure(InvocationError.cancelled))
                        } else {
                            resumeOnce(.success((out, err, proc.terminationStatus)))
                        }
                    }

                    do {
                        try process.run()
                    } catch {
                        resumeOnce(.failure(InvocationError.launchFailed(String(describing: error))))
                        return
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
                        resumeOnce(.failure(InvocationError.timeout))

                        // Give the child 1 second to honor SIGTERM, then SIGKILL.
                        // The `claude` CLI is well-behaved Node and responds to
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
