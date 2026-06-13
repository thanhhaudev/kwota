//
//  CodexCLIRunner.swift
//  Kwota
//
//  Spawns OpenAI's `codex` CLI in headless mode (`codex exec`) to run a
//  one-shot prompt — the Codex counterpart of `ClaudeCLIRunner`. Routing
//  through the CLI inherits the user's ChatGPT-subscription login from
//  ~/.codex/auth.json (no API key needed) at the cost of consuming that
//  subscription's quota, exactly like the Claude path.
//
//  Invocation shape (codex-cli ≥ 0.137):
//
//      codex exec --ephemeral --skip-git-repo-check --sandbox read-only
//                 -c mcp_servers={} -c plugins={} --color never
//                 -o <tmp>/last-message.json
//                 [--output-schema <tmp>/schema.json] [-m <model>] -
//
//  The prompt arrives on stdin (`-`). `--output-schema` forces the final
//  agent message to conform to the given JSON Schema; `-o` writes that
//  message to a file so we never scrape the event stream on stdout.
//  `--ignore-user-config` is deliberately NOT used: the "Codex default"
//  model choice resolves from the user's config.toml, and auth must keep
//  working. MCP servers and the user's plugins are suppressed via `-c`
//  overrides instead.
//
//  There is no `--system-prompt` flag — system + user prompts are merged
//  into one stdin payload with an explicit <instructions> block.
//

import Foundation

final class CodexCLIRunner: AgentCLIInvocation {
    /// Candidate locations for the `codex` binary, in priority order.
    /// Same footprints as the Claude CLI: vendor installer, npm globals,
    /// Homebrew. NSTask doesn't inherit the interactive shell PATH, so an
    /// explicit list beats `which`.
    static let candidatePaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
    }()

    private let resolveBinary: @Sendable () -> String?

    init(resolveBinary: @escaping @Sendable () -> String? = CodexCLIRunner.defaultBinaryResolver) {
        self.resolveBinary = resolveBinary
    }

    /// First candidate path that is executable, or nil if none match.
    /// Checks the fixed footprints first, then nvm's versioned node bins
    /// (`~/.nvm/versions/node/<ver>/bin/codex`) — a common install method
    /// the fixed list can't enumerate. Tests inject their own resolver to
    /// bypass disk probing.
    static let defaultBinaryResolver: @Sendable () -> String? = {
        let fm = FileManager.default
        for path in candidatePaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nvmCandidate(fileManager: fm)
    }

    /// Newest nvm-installed `codex`, or nil. Sorted descending by the
    /// version directory name so the latest node version wins; falls back
    /// to lexicographic order, which is good enough for picking *a*
    /// working binary.
    static func nvmCandidate(fileManager fm: FileManager) -> String? {
        let home = fm.homeDirectoryForCurrentUser.path
        let versionsDir = "\(home)/.nvm/versions/node"
        guard let versions = try? fm.contentsOfDirectory(atPath: versionsDir) else {
            return nil
        }
        for version in versions.sorted(by: >) {
            let candidate = "\(versionsDir)/\(version)/bin/codex"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
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

        // Per-invocation scratch dir: neutral cwd for the process, plus a
        // home for the schema + last-message files. Removed on the way out
        // regardless of outcome.
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("kwota-codex-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            throw CLIInvocationError.launchFailed("couldn't create scratch dir: \(error)")
        }
        defer { try? fm.removeItem(at: workDir) }

        let outputFile = workDir.appendingPathComponent("last-message.json")
        var schemaFile: URL?
        if let jsonSchema {
            let file = workDir.appendingPathComponent("schema.json")
            do {
                try Data(jsonSchema.utf8).write(to: file)
            } catch {
                throw CLIInvocationError.launchFailed("couldn't write schema file: \(error)")
            }
            schemaFile = file
        }

        let args = Self.buildArguments(
            model: model,
            schemaFile: schemaFile?.path,
            outputFile: outputFile.path
        )
        let stdin = Data(
            Self.mergedPrompt(systemPrompt: systemPrompt, userPrompt: userPrompt).utf8
        )

        let (_, stderrData, exitCode) = try await CLIProcess.run(
            binary: binary,
            args: args,
            stdin: stdin,
            currentDirectory: workDir,
            environment: Self.childEnvironment(forBinary: binary),
            timeout: timeout
        )
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch Self.interpret(
            exitCode: exitCode,
            stderr: stderr,
            lastMessageData: try? Data(contentsOf: outputFile),
            jsonSchemaUsed: jsonSchema != nil
        ) {
        case .success(let text): return Self.makeAnswer(output: text)
        case .failure(let err): throw err
        }
    }

    /// Wrap a codex output string in a `CLIAnswer`. Codex doesn't expose
    /// the resolved model without parsing its event stream, so
    /// `resolvedModel` is always nil — provenance falls back to the label.
    static func makeAnswer(output: String) -> CLIAnswer {
        CLIAnswer(output: output, resolvedModel: nil)
    }

    /// Environment for the spawned `codex` process. The nvm/Homebrew
    /// `codex` is a `#!/usr/bin/env node` script, so the child must find
    /// `node` on PATH — and a Finder-launched .app inherits only a minimal
    /// PATH. `node` sits in the same directory as `codex` for nvm installs,
    /// so we prepend the binary's own directory, then the repo's standard
    /// augmented PATH, then whatever PATH we already had. Non-PATH
    /// variables pass through untouched (auth/home lookups rely on them).
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

    /// `codex exec` argument list. Pure + static for direct test coverage
    /// of flag adjacency and isolation invariants.
    static func buildArguments(
        model: String?,
        schemaFile: String?,
        outputFile: String
    ) -> [String] {
        var args = [
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "-c", "mcp_servers={}",
            "-c", "plugins={}",
            "--color", "never",
            "-o", outputFile,
        ]
        if let schemaFile {
            args.append(contentsOf: ["--output-schema", schemaFile])
        }
        if let model {
            args.append(contentsOf: ["-m", model])
        }
        args.append("-") // read the prompt from stdin
        return args
    }

    /// Merge the system + user prompts into one stdin payload. `codex
    /// exec` has no system-prompt flag, so the framing rides in an
    /// explicit instructions block ahead of the user content.
    static func mergedPrompt(systemPrompt: String, userPrompt: String) -> String {
        """
        <instructions>
        \(systemPrompt)
        </instructions>

        \(userPrompt)
        """
    }

    /// Decode an exec run into the model's answer or a typed error. Pure +
    /// static so tests exercise every branch without a subprocess.
    ///
    /// Codex reports its own failures (auth, quota) via non-zero exit with
    /// the message on stderr — there is no is_error envelope like Claude's.
    static func interpret(
        exitCode: Int32,
        stderr: String,
        lastMessageData: Data?,
        jsonSchemaUsed: Bool
    ) -> Result<String, CLIInvocationError> {
        guard exitCode == 0 else {
            let detail = stderr.isEmpty ? "codex exited with status \(exitCode)" : stderr
            return .failure(.nonZeroExit(status: exitCode, message: detail))
        }
        guard
            let data = lastMessageData,
            let raw = String(data: data, encoding: .utf8)
        else {
            return .failure(.malformedOutput("codex wrote no last message"))
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .failure(.malformedOutput("codex wrote an empty last message"))
        }
        if jsonSchemaUsed {
            // --output-schema should guarantee JSON; verify before handing
            // the string to JSONDecoder so a CLI regression surfaces as a
            // typed malformedOutput instead of a downstream parseFailed.
            guard
                let jsonData = text.data(using: .utf8),
                (try? JSONSerialization.jsonObject(with: jsonData)) != nil
            else {
                return .failure(.malformedOutput("last message is not valid JSON"))
            }
        }
        return .success(text)
    }
}
