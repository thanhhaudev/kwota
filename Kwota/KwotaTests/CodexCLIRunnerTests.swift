//
//  CodexCLIRunnerTests.swift
//  KwotaTests
//
//  Pure-function coverage for the codex exec runner: argument
//  construction, prompt merging, and result interpretation — every
//  branch without spawning a subprocess (the `interpretResult` pattern
//  from ClaudeCLIRunner).
//

import XCTest
@testable import Kwota

final class CodexCLIRunnerTests: XCTestCase {

    // MARK: - buildArguments

    func testBuildArgumentsOmitsModelForDefault() {
        let args = CodexCLIRunner.buildArguments(
            model: nil, schemaFile: "/tmp/s.json", outputFile: "/tmp/o.json"
        )
        XCTAssertFalse(args.contains("-m"),
                       "nil model must omit -m so codex uses its configured default")
    }

    func testBuildArgumentsIncludesModelSchemaAndOutput() {
        let args = CodexCLIRunner.buildArguments(
            model: "gpt-5.4-mini", schemaFile: "/tmp/s.json", outputFile: "/tmp/o.json"
        )
        XCTAssertEqual(args.first, "exec")
        // Flag/value adjacency matters — assert pairs, not membership.
        if let i = args.firstIndex(of: "-m") {
            XCTAssertEqual(args[i + 1], "gpt-5.4-mini")
        } else { XCTFail("missing -m") }
        if let i = args.firstIndex(of: "--output-schema") {
            XCTAssertEqual(args[i + 1], "/tmp/s.json")
        } else { XCTFail("missing --output-schema") }
        if let i = args.firstIndex(of: "-o") {
            XCTAssertEqual(args[i + 1], "/tmp/o.json")
        } else { XCTFail("missing -o") }
    }

    func testBuildArgumentsIsolatesTheRun() {
        let args = CodexCLIRunner.buildArguments(
            model: nil, schemaFile: nil, outputFile: "/tmp/o.json"
        )
        XCTAssertTrue(args.contains("--ephemeral"), "must not persist session files")
        XCTAssertTrue(args.contains("--skip-git-repo-check"))
        if let i = args.firstIndex(of: "--sandbox") {
            XCTAssertEqual(args[i + 1], "read-only")
        } else { XCTFail("missing --sandbox") }
        // Two -c overrides now; assert both values are present as
        // flag/value adjacencies.
        let cIndices = args.indices.filter { args[$0] == "-c" }
        let cValues = cIndices.map { args[$0 + 1] }
        XCTAssertTrue(cValues.contains("mcp_servers={}"),
                      "user MCP servers must not load into an evaluation")
        XCTAssertTrue(cValues.contains("plugins={}"),
                      "user plugins must not load into an evaluation")
        XCTAssertFalse(args.contains("--ignore-user-config"),
                       "config must load — codexDefault resolves its model there")
    }

    func testBuildArgumentsEndsWithStdinSentinel() {
        let args = CodexCLIRunner.buildArguments(
            model: nil, schemaFile: nil, outputFile: "/tmp/o.json"
        )
        XCTAssertEqual(args.last, "-", "prompt arrives on stdin")
    }

    func testBuildArgumentsOmitsSchemaFlagWhenNoSchema() {
        let args = CodexCLIRunner.buildArguments(
            model: nil, schemaFile: nil, outputFile: "/tmp/o.json"
        )
        XCTAssertFalse(args.contains("--output-schema"))
    }

    // MARK: - mergedPrompt

    func testMergedPromptWrapsSystemInInstructionsBlock() {
        let merged = CodexCLIRunner.mergedPrompt(
            systemPrompt: "You are a classifier.",
            userPrompt: "Evaluate /tmp/x"
        )
        XCTAssertTrue(merged.contains("<instructions>\nYou are a classifier.\n</instructions>"))
        // Instructions must precede the user content.
        let instructionsEnd = merged.range(of: "</instructions>")!.upperBound
        XCTAssertTrue(merged[instructionsEnd...].contains("Evaluate /tmp/x"))
    }

    // MARK: - interpret

    func testInterpretNonZeroExitCarriesStderr() {
        let result = CodexCLIRunner.interpret(
            exitCode: 1, stderr: "Not logged in. Run codex login.",
            lastMessageData: nil, jsonSchemaUsed: true
        )
        guard case .failure(.nonZeroExit(let status, let message)) = result else {
            return XCTFail("expected nonZeroExit, got \(result)")
        }
        XCTAssertEqual(status, 1)
        XCTAssertEqual(message, "Not logged in. Run codex login.")
    }

    func testInterpretNonZeroExitWithEmptyStderrGetsFallbackMessage() {
        let result = CodexCLIRunner.interpret(
            exitCode: 2, stderr: "", lastMessageData: nil, jsonSchemaUsed: true
        )
        guard case .failure(.nonZeroExit(_, let message)) = result else {
            return XCTFail("expected nonZeroExit, got \(result)")
        }
        XCTAssertFalse(message.isEmpty, "banner copy needs a non-empty detail")
    }

    func testInterpretMissingLastMessageIsMalformed() {
        let result = CodexCLIRunner.interpret(
            exitCode: 0, stderr: "", lastMessageData: nil, jsonSchemaUsed: true
        )
        guard case .failure(.malformedOutput) = result else {
            return XCTFail("expected malformedOutput, got \(result)")
        }
    }

    func testInterpretEmptyLastMessageIsMalformed() {
        let result = CodexCLIRunner.interpret(
            exitCode: 0, stderr: "", lastMessageData: Data("  \n".utf8), jsonSchemaUsed: true
        )
        guard case .failure(.malformedOutput) = result else {
            return XCTFail("expected malformedOutput, got \(result)")
        }
    }

    func testInterpretRejectsNonJSONWhenSchemaUsed() {
        let result = CodexCLIRunner.interpret(
            exitCode: 0, stderr: "",
            lastMessageData: Data("Sure! Here is the evaluation:".utf8),
            jsonSchemaUsed: true
        )
        guard case .failure(.malformedOutput) = result else {
            return XCTFail("expected malformedOutput, got \(result)")
        }
    }

    func testInterpretReturnsTrimmedJSONOnHappyPath() {
        let json = #"{"safety": "safe", "purpose": "npm cache"}"#
        let result = CodexCLIRunner.interpret(
            exitCode: 0, stderr: "",
            lastMessageData: Data("\n\(json)\n".utf8), jsonSchemaUsed: true
        )
        guard case .success(let out) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(out, json)
    }

    func testInterpretAllowsPlainTextWhenNoSchema() {
        let result = CodexCLIRunner.interpret(
            exitCode: 0, stderr: "",
            lastMessageData: Data("plain answer".utf8), jsonSchemaUsed: false
        )
        guard case .success(let out) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(out, "plain answer")
    }

    // MARK: - childEnvironment

    func testChildEnvironmentPutsBinaryDirOnPathFirst() {
        // nvm's codex is `#!/usr/bin/env node`; node lives in the same dir.
        // The spawned child must see that dir on PATH or the shebang fails
        // with "env: node: No such file or directory".
        let env = CodexCLIRunner.childEnvironment(
            forBinary: "/Users/me/.nvm/versions/node/v20.20.0/bin/codex",
            baseEnvironment: ["PATH": "/usr/bin:/bin"]
        )
        let path = env["PATH"] ?? ""
        let binDir = "/Users/me/.nvm/versions/node/v20.20.0/bin"
        XCTAssertTrue(path.split(separator: ":").map(String.init).contains(binDir),
                      "codex's own directory must be on PATH so its sibling node resolves")
        XCTAssertTrue(path.hasPrefix(binDir + ":"),
                      "the binary dir should come first so the co-located node wins")
        // The pre-existing PATH entries must still be present (appended).
        XCTAssertTrue(path.contains("/usr/bin"), "existing PATH must be preserved")
    }

    func testChildEnvironmentPreservesOtherVariables() {
        let env = CodexCLIRunner.childEnvironment(
            forBinary: "/opt/homebrew/bin/codex",
            baseEnvironment: ["PATH": "/usr/bin", "HOME": "/Users/me", "FOO": "bar"]
        )
        XCTAssertEqual(env["HOME"], "/Users/me", "non-PATH vars must pass through (auth/home lookups)")
        XCTAssertEqual(env["FOO"], "bar")
    }

    // MARK: - ask (resolver seam only — no subprocess)

    func testAskThrowsNotInstalledWhenResolverFindsNothing() async {
        let runner = CodexCLIRunner(resolveBinary: { nil })
        do {
            _ = try await runner.ask(
                systemPrompt: "s", userPrompt: "u", model: nil,
                jsonSchema: nil, timeout: 5
            )
            XCTFail("expected notInstalled")
        } catch let err as CLIInvocationError {
            XCTAssertEqual(err, .notInstalled)
        } catch {
            XCTFail("expected CLIInvocationError, got \(error)")
        }
    }
}
