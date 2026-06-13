//
//  CacheAIEngineTests.swift
//  KwotaTests
//
//  Contract tests for the Cache → AI engine + Codex model enums. Raw
//  values are persisted in cache-state.json and forwarded to CLI flags,
//  so they're load-bearing — lock them down.
//

import XCTest
@testable import Kwota

final class CacheAIEngineTests: XCTestCase {

    // MARK: - CacheAIEngine

    func testEngineRawValuesAreStable() {
        XCTAssertEqual(CacheAIEngine.claude.rawValue, "claude")
        XCTAssertEqual(CacheAIEngine.codex.rawValue, "codex")
    }

    func testEngineDefaultIsClaude() {
        XCTAssertEqual(CacheAIEngine.default, .claude)
    }

    func testEngineCLICommandMatchesBinaryName() {
        // Error copy interpolates this into "the `<cmd>` command" — it must
        // be the literal binary name, not a display name.
        XCTAssertEqual(CacheAIEngine.claude.cliCommand, "claude")
        XCTAssertEqual(CacheAIEngine.codex.cliCommand, "codex")
    }

    // MARK: - CodexModelChoice

    func testCodexDefaultOmitsModelArg() {
        XCTAssertNil(CodexModelChoice.codexDefault.cliModelArg,
                     "default must omit -m so codex reads ~/.codex/config.toml")
    }

    func testExplicitModelsForwardSlugVerbatim() {
        XCTAssertEqual(CodexModelChoice.gpt55.cliModelArg, "gpt-5.5")
        XCTAssertEqual(CodexModelChoice.gpt54.cliModelArg, "gpt-5.4")
        XCTAssertEqual(CodexModelChoice.gpt54Mini.cliModelArg, "gpt-5.4-mini")
    }

    func testProvenanceLabels() {
        // codexDefault stamps a stable placeholder (the resolved model
        // isn't knowable without parsing the CLI event stream); explicit
        // choices stamp the real slug.
        XCTAssertEqual(CodexModelChoice.codexDefault.provenanceLabel, "codex-default")
        XCTAssertEqual(CodexModelChoice.gpt54Mini.provenanceLabel, "gpt-5.4-mini")
    }

    func testCodexModelDefaultIsCodexDefault() {
        XCTAssertEqual(CodexModelChoice.default, .codexDefault)
    }
}
