//
//  AntigravityCLIRunnerTests.swift
//  KwotaTests
//
//  Pure-function coverage for the agy runner: argument construction,
//  schema-embedding prompt, and the tolerant JSON extractor — agy has no
//  --json-schema, so the response may arrive fenced or wrapped in prose.
//

import XCTest
@testable import Kwota

final class AntigravityCLIRunnerTests: XCTestCase {

    // MARK: - buildArguments

    func testBuildArgumentsRunsHeadlessSandboxed() {
        let args = AntigravityCLIRunner.buildArguments(prompt: "hi", timeoutSeconds: 90)
        XCTAssertTrue(args.contains("--sandbox"), "must run sandboxed")
        if let i = args.firstIndex(of: "-p") {
            XCTAssertEqual(args[i + 1], "hi", "the prompt is the value of -p")
        } else { XCTFail("missing -p") }
        if let i = args.firstIndex(of: "--print-timeout") {
            XCTAssertEqual(args[i + 1], "90s", "timeout passed as <N>s")
        } else { XCTFail("missing --print-timeout") }
    }

    // MARK: - mergedPrompt

    func testMergedPromptEmbedsSchemaAndBansTools() {
        let merged = AntigravityCLIRunner.mergedPrompt(
            systemPrompt: "SYS", userPrompt: "USER",
            jsonSchema: #"{"type":"object"}"#
        )
        XCTAssertTrue(merged.contains("SYS"))
        XCTAssertTrue(merged.contains("USER"))
        XCTAssertTrue(merged.contains(#"{"type":"object"}"#), "schema embedded verbatim")
        XCTAssertTrue(merged.lowercased().contains("only a json"),
                      "must instruct JSON-only output")
        XCTAssertTrue(merged.lowercased().contains("do not"),
                      "must forbid tool use / folder reads")
        XCTAssertLessThan(merged.range(of: "SYS")!.lowerBound,
                          merged.range(of: "USER")!.lowerBound)
    }

    // MARK: - extractJSON

    func testExtractCleanJSON() {
        let raw = #"{"safety":"safe","purpose":"p"}"#
        XCTAssertEqual(AntigravityCLIRunner.extractJSON(from: raw), raw)
    }

    func testExtractStripsCodeFence() {
        let raw = "```json\n{\"safety\":\"safe\",\"purpose\":\"p\"}\n```"
        XCTAssertEqual(AntigravityCLIRunner.extractJSON(from: raw),
                       #"{"safety":"safe","purpose":"p"}"#)
    }

    func testExtractStripsLeadingAndTrailingProse() {
        let raw = "Here is the result:\n{\"safety\":\"risky\",\"purpose\":\"p\"}\nHope that helps!"
        XCTAssertEqual(AntigravityCLIRunner.extractJSON(from: raw),
                       #"{"safety":"risky","purpose":"p"}"#)
    }

    func testExtractHandlesBracesInsideStrings() {
        let raw = #"prefix {"purpose":"uses {curly} braces","safety":"safe"} suffix"#
        XCTAssertEqual(AntigravityCLIRunner.extractJSON(from: raw),
                       #"{"purpose":"uses {curly} braces","safety":"safe"}"#)
    }

    func testExtractBulkObject() {
        let raw = "```\n{\"evaluations\":[{\"path\":\"/a\",\"safety\":\"safe\",\"purpose\":\"p\"}]}\n```"
        XCTAssertEqual(AntigravityCLIRunner.extractJSON(from: raw),
                       #"{"evaluations":[{"path":"/a","safety":"safe","purpose":"p"}]}"#)
    }

    func testExtractReturnsNilOnNoJSON() {
        XCTAssertNil(AntigravityCLIRunner.extractJSON(from: "I cannot help with that."))
    }

    func testExtractReturnsNilOnUnbalancedBraces() {
        XCTAssertNil(AntigravityCLIRunner.extractJSON(from: #"{"safety":"safe""#))
    }

    // MARK: - ask (resolver seam)

    func testAskThrowsNotInstalledWhenResolverFindsNothing() async {
        let runner = AntigravityCLIRunner(resolveBinary: { nil })
        do {
            _ = try await runner.ask(systemPrompt: "s", userPrompt: "u",
                                     model: nil, jsonSchema: "{}", timeout: 5)
            XCTFail("expected notInstalled")
        } catch let err as CLIInvocationError {
            XCTAssertEqual(err, .notInstalled)
        } catch {
            XCTFail("expected CLIInvocationError, got \(error)")
        }
    }
}
