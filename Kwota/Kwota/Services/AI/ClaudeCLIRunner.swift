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
//             --no-session-persistence --disable-slash-commands
//             --strict-mcp-config --tools "" --setting-sources project
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

final class ClaudeCLIRunner: AgentCLIInvocation {
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
    ) async throws -> CLIAnswer {
        guard let binary = resolveBinary() else {
            throw CLIInvocationError.notInstalled
        }

        let args = Self.buildArguments(
            userPrompt: userPrompt,
            systemPrompt: systemPrompt,
            model: model,
            jsonSchema: jsonSchema
        )
        let schemaUsed = jsonSchema != nil

        let (stdoutData, stderrData, exitCode) = try await CLIProcess.run(
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
        case .success(let answer): return answer
        case .failure(let err): throw err
        }
    }

    /// `claude -p` argument list. Pure + static for direct test coverage
    /// (mirrors `CodexCLIRunner.buildArguments`).
    ///
    /// `--output-format json` wraps the run in an envelope; `--json-schema`
    /// forces the answer into its `structured_output` field.
    ///
    /// Isolation flags. `--bare` would do most of this in one shot but also
    /// disables keychain reads → no OAuth, so we strip the local Claude Code
    /// environment piecemeal instead:
    ///   --no-session-persistence  don't write this one-shot eval to
    ///                             `~/.claude/projects`. Without it, `claude -p`
    ///                             persists a session transcript that the Awake
    ///                             activity chart's `scanClaudeBackfill` counts
    ///                             as a Claude agent reply — surfacing Kwota's
    ///                             own cache evaluations as phantom user
    ///                             activity. (Codex's runner isolates the same
    ///                             way via `exec --ephemeral`; agy has no such
    ///                             flag, so the Antigravity chart filters by
    ///                             transcript content instead.)
    ///   --disable-slash-commands  no skills
    ///   --strict-mcp-config       no MCP servers (no --mcp-config given)
    ///   --tools ""                no tools → deterministic one-shot, and no
    ///                             PreToolUse hooks can fire
    ///   --setting-sources project only project-scoped settings; the neutral
    ///                             cwd has none, so the user's hooks never load
    /// This keeps the evaluation reproducible and cuts ~94% of the
    /// cached-context tokens the user would otherwise be billed for.
    static func buildArguments(
        userPrompt: String,
        systemPrompt: String,
        model: String?,
        jsonSchema: String?
    ) -> [String] {
        var args = [
            "-p", userPrompt,
            "--system-prompt", systemPrompt,
            "--output-format", "json",
            "--no-session-persistence",
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
        return args
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
    ) -> Result<CLIAnswer, CLIInvocationError> {
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
            return .success(CLIAnswer(output: resultText, resolvedModel: Self.resolvedModel(from: root)))
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
        return .success(CLIAnswer(output: json, resolvedModel: Self.resolvedModel(from: root)))
    }

    /// The real model the CLI used, from the `--output-format json`
    /// envelope's `modelUsage` map (keyed by model ID). When an alias was
    /// requested (e.g. `--model opus`) this is the resolved version. If a
    /// fallback model kicked in mid-run there can be >1 key — pick the one
    /// with the most output tokens (the primary responder). nil when absent.
    static func resolvedModel(from root: [String: Any]) -> String? {
        guard let usage = root["modelUsage"] as? [String: Any], !usage.isEmpty else {
            return nil
        }
        func outputTokens(_ v: Any) -> Int { (v as? [String: Any])?["outputTokens"] as? Int ?? 0 }
        return usage.max { outputTokens($0.value) < outputTokens($1.value) }?.key
    }

}
