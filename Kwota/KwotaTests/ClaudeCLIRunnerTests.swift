//
//  ClaudeCLIRunnerTests.swift
//  KwotaTests
//
//  Pure-function coverage for the `claude -p` runner's argument
//  construction — no subprocess. (`interpretResult` is covered by
//  CacheAIEvaluationTests.)
//

import XCTest
@testable import Kwota

final class ClaudeCLIRunnerTests: XCTestCase {

    // MARK: - buildArguments

    func testBuildArgumentsCarriesPromptPairs() {
        let args = ClaudeCLIRunner.buildArguments(
            userPrompt: "U", systemPrompt: "S", model: nil, jsonSchema: nil)
        // Flag/value adjacency matters — assert pairs, not membership.
        XCTAssertEqual(args.first, "-p")
        XCTAssertEqual(args[1], "U")
        if let i = args.firstIndex(of: "--system-prompt") {
            XCTAssertEqual(args[i + 1], "S")
        } else { XCTFail("missing --system-prompt") }
        if let i = args.firstIndex(of: "--output-format") {
            XCTAssertEqual(args[i + 1], "json")
        } else { XCTFail("missing --output-format") }
    }

    /// The evaluation must not be written to `~/.claude/projects` — otherwise
    /// the Awake chart's `scanClaudeBackfill` counts Kwota's own cache eval as
    /// phantom Claude activity. This flag is the source-level fix (mirrors
    /// Codex's `--ephemeral`); guard it so a refactor can't silently drop it.
    func testBuildArgumentsDisablesSessionPersistence() {
        let args = ClaudeCLIRunner.buildArguments(
            userPrompt: "U", systemPrompt: "S", model: "haiku", jsonSchema: "{}")
        XCTAssertTrue(args.contains("--no-session-persistence"),
                      "cache-eval runs must not persist to ~/.claude/projects")
    }

    func testBuildArgumentsIsolatesTheRun() {
        let args = ClaudeCLIRunner.buildArguments(
            userPrompt: "U", systemPrompt: "S", model: nil, jsonSchema: nil)
        XCTAssertTrue(args.contains("--disable-slash-commands"))
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        if let i = args.firstIndex(of: "--tools") {
            XCTAssertEqual(args[i + 1], "")
        } else { XCTFail("missing --tools") }
        if let i = args.firstIndex(of: "--setting-sources") {
            XCTAssertEqual(args[i + 1], "project")
        } else { XCTFail("missing --setting-sources") }
    }

    func testBuildArgumentsOmitsModelAndSchemaWhenNil() {
        let args = ClaudeCLIRunner.buildArguments(
            userPrompt: "U", systemPrompt: "S", model: nil, jsonSchema: nil)
        XCTAssertFalse(args.contains("--model"), "nil model → let the CLI default decide")
        XCTAssertFalse(args.contains("--json-schema"), "nil schema → no structured-output flag")
    }

    func testBuildArgumentsIncludesModelAndSchemaWhenSet() {
        let args = ClaudeCLIRunner.buildArguments(
            userPrompt: "U", systemPrompt: "S", model: "sonnet", jsonSchema: "{\"x\":1}")
        if let i = args.firstIndex(of: "--model") {
            XCTAssertEqual(args[i + 1], "sonnet")
        } else { XCTFail("missing --model") }
        if let i = args.firstIndex(of: "--json-schema") {
            XCTAssertEqual(args[i + 1], "{\"x\":1}")
        } else { XCTFail("missing --json-schema") }
    }
}
