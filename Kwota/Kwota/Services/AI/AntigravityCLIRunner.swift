//
//  AntigravityCLIRunner.swift
//  Kwota
//
//  Spawns Antigravity's `agy` CLI in headless mode (`agy -p`) to run a
//  one-shot prompt — the Antigravity counterpart of ClaudeCLIRunner /
//  CodexCLIRunner. `agy -p` runs without the GUI app or any daemon and
//  prints the model's response to stdout, consuming the user's
//  Antigravity (Gemini) subscription quota.
//
//  Two things set agy apart from the other engines:
//   1. No `--json-schema` / `--output-schema` flag — structured output
//      can only be *requested* in the prompt, so the schema is embedded
//      in the prompt text and the response is run through a tolerant
//      `extractJSON` (the model may wrap it in a ```json fence or prose).
//   2. No `--model` flag — agy uses Antigravity's default model, so the
//      `model` parameter is ignored and provenance stamps a fixed label.
//
//  Invocation: `agy -p <merged-prompt> --sandbox --print-timeout <N>s`.
//  `--sandbox` plus a prompt that forbids tool use keeps the run a pure
//  one-shot classification; `--print-timeout` is the CLI-side backstop.
//

import Foundation

final class AntigravityCLIRunner: AgentCLIInvocation {
    /// Candidate locations for the `agy` binary, in priority order — same
    /// footprints as the other runners. NSTask doesn't inherit the
    /// interactive shell PATH, so an explicit list beats `which`.
    static let candidatePaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/agy",
            "\(home)/.npm-global/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
    }()

    private let resolveBinary: @Sendable () -> String?

    init(resolveBinary: @escaping @Sendable () -> String? = AntigravityCLIRunner.defaultBinaryResolver) {
        self.resolveBinary = resolveBinary
    }

    /// First candidate path that is executable, or nil if none match.
    /// Tests inject their own resolver to bypass disk probing.
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

        // Neutral cwd so agy's workspace auto-discovery can't pick up the
        // host app's launch directory. Removed regardless of outcome.
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("kwota-agy-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            throw CLIInvocationError.launchFailed("couldn't create scratch dir: \(error)")
        }
        defer { try? fm.removeItem(at: workDir) }

        let prompt = Self.mergedPrompt(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            jsonSchema: jsonSchema ?? ""
        )
        let args = Self.buildArguments(prompt: prompt, timeoutSeconds: Int(timeout))

        let (stdoutData, stderrData, exitCode) = try await CLIProcess.run(
            binary: binary,
            args: args,
            currentDirectory: workDir,
            environment: Self.childEnvironment(forBinary: binary),
            timeout: timeout
        )
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard exitCode == 0 else {
            let detail = stderr.isEmpty ? "agy exited with status \(exitCode)" : stderr
            throw CLIInvocationError.nonZeroExit(status: exitCode, message: detail)
        }
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        guard let json = Self.extractJSON(from: stdout) else {
            throw CLIInvocationError.malformedOutput(
                "agy response had no parseable JSON object")
        }
        // agy exposes no resolved model — provenance falls back to the label.
        return CLIAnswer(output: json, resolvedModel: nil)
    }

    /// `agy -p` argument list. Pure + static for direct test coverage.
    /// `-p` takes the prompt as its value; `--sandbox` restricts the run;
    /// `--print-timeout` is the CLI-side wait backstop.
    static func buildArguments(prompt: String, timeoutSeconds: Int) -> [String] {
        ["-p", prompt, "--sandbox", "--print-timeout", "\(timeoutSeconds)s"]
    }

    /// Build the single prompt agy runs. Since agy can't enforce a schema,
    /// the schema is embedded and the model is told to emit ONLY JSON and
    /// to classify from the path alone (no tools, no folder reads), so the
    /// sandboxed run stays a pure one-shot.
    static func mergedPrompt(systemPrompt: String, userPrompt: String, jsonSchema: String) -> String {
        """
        \(systemPrompt)

        \(userPrompt)

        Respond with ONLY a JSON object that matches the schema below. No \
        markdown fences, no prose, no explanation. Classify from the path \
        alone — do not read the folder or use any tools.

        Schema:
        \(jsonSchema)
        """
    }

    /// Environment for the spawned `agy` process: prepend the binary's own
    /// directory, then the repo's standard augmented PATH, so any helper
    /// agy shells out to resolves even under a Finder-launched app's
    /// minimal PATH. Non-PATH variables pass through (auth/home lookups).
    static func childEnvironment(
        forBinary binary: String,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = baseEnvironment
        let binDir = (binary as NSString).deletingLastPathComponent
        let augmented = ClaudeProbe.augmentedPATH(existing: env["PATH"] ?? "")
        env["PATH"] = binDir.isEmpty ? augmented : "\(binDir):\(augmented)"
        return env
    }

    /// Extract the first balanced top-level JSON object from agy's printed
    /// response. agy can't enforce a schema, so the response may be clean
    /// JSON, wrapped in a ```json code fence, or surrounded by prose.
    /// Strips fences, scans from the first `{` to its matching `}` (brace
    /// depth, ignoring braces inside string literals), and validates the
    /// result as JSON. Returns nil when nothing parseable is found →
    /// caller raises `.malformedOutput`.
    static func extractJSON(from raw: String) -> String? {
        // Strip a wrapping markdown code fence if present.
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fenceClose = text.range(of: "```", options: .backwards) {
                text = String(text[..<fenceClose.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"": inString = true
                case "{":  depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        let candidate = String(text[start...idx])
                        guard let data = candidate.data(using: .utf8),
                              (try? JSONSerialization.jsonObject(with: data)) != nil
                        else { return nil }
                        return candidate
                    }
                default: break
                }
            }
            idx = text.index(after: idx)
        }
        return nil // never balanced
    }
}
