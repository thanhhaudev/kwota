//
//  AgentCLIInvocation.swift
//  Kwota
//
//  Engine-agnostic contract for headless one-shot CLI invocations
//  (Claude's `claude -p`, Codex's `codex exec`). `CacheEvaluator` talks
//  to this protocol only — selecting an engine is the view model's job.
//

import Foundation

/// Headless invocation of a vendor agent CLI.
protocol AgentCLIInvocation: Sendable {
    /// Runs the CLI headless and returns the model's answer as a JSON
    /// string. When `jsonSchema` is non-nil the returned string is
    /// guaranteed to be schema-conformant JSON; when nil it's plain text.
    /// Throws `CLIInvocationError` on any failure.
    func ask(
        systemPrompt: String,
        userPrompt: String,
        model: String?,
        jsonSchema: String?,
        timeout: TimeInterval
    ) async throws -> String
}

/// Failure modes the cache evaluator wants to distinguish in the UI.
/// Shared vocabulary for every `AgentCLIInvocation` implementation.
enum CLIInvocationError: Error, Equatable {
    /// CLI binary not found in any candidate location.
    case notInstalled
    /// `Process.run()` itself threw before the CLI started.
    case launchFailed(String)
    /// Process exited non-zero without a recognizable answer.
    case nonZeroExit(status: Int32, message: String)
    /// The CLI ran but reported an error itself (auth failure, quota,
    /// etc.) — carries the CLI's own message.
    case cliReportedError(String)
    /// Output couldn't be parsed, or the schema-validated answer was
    /// missing when a schema was requested.
    case malformedOutput(String)
    /// Process took longer than the configured timeout.
    case timeout
    /// The caller's Task was cancelled; the child process has been
    /// terminated (SIGTERM + SIGKILL escalation after 1 s).
    case cancelled
}
