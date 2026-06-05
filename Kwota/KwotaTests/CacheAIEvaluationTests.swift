//
//  CacheAIEvaluationTests.swift
//  KwotaTests
//
//  Coverage for the Cache → AI feature's pure parts: effective-risk
//  override, prompt templates, JSON parsing on CLI output, and the
//  evaluator's success/error mapping. Live `claude` invocation isn't
//  hit — `StubCLIRunner` injects canned stdout strings (or canned
//  errors) so we can assert behavior deterministically.
//

import XCTest
@testable import Kwota

/// Test double for `ClaudeCLIInvocation`. Either returns a canned
/// `structured_output` JSON string or throws a canned error — covers the
/// `EvaluationError` paths plus the happy path without spawning a
/// subprocess.
private final class StubCLIRunner: ClaudeCLIInvocation, @unchecked Sendable {
    enum Outcome {
        case success(String)
        case failure(Error)
    }
    var outcome: Outcome

    init(outcome: Outcome) { self.outcome = outcome }

    func ask(
        systemPrompt: String,
        userPrompt: String,
        model: String?,
        jsonSchema: String?,
        timeout: TimeInterval
    ) async throws -> String {
        switch outcome {
        case .success(let out): return out
        case .failure(let err): throw err
        }
    }
}

final class CacheAIEvaluationTests: XCTestCase {

    // MARK: - effectiveRisk

    func testEffectiveRiskFallsBackToHandCuratedWhenNoEval() {
        let row = makeRow(handCurated: .caution, eval: nil)
        XCTAssertEqual(row.effectiveRisk, .caution)
    }

    func testEffectiveRiskUsesAISafeOverridingHandCuratedCaution() {
        let row = makeRow(
            handCurated: .caution,
            eval: makeEval(safety: .safe)
        )
        // AI looked at the actual folder and said it's safe — the hand-
        // curated caution chip should give way.
        XCTAssertEqual(row.effectiveRisk, .safe)
    }

    func testEffectiveRiskUsesAIRiskyOverridingHandCuratedSafe() {
        let row = makeRow(
            handCurated: .safe,
            eval: makeEval(safety: .risky)
        )
        XCTAssertEqual(row.effectiveRisk, .risky)
    }

    func testEffectiveRiskFallsBackOnUnknownVerdict() {
        // `.unknown` means the model abstained — we don't downgrade the
        // user's hand-curated hint to "no chip".
        let row = makeRow(
            handCurated: .caution,
            eval: makeEval(safety: .unknown)
        )
        XCTAssertEqual(row.effectiveRisk, .caution)
    }

    // MARK: - Prompts

    func testSystemSinglePromptMentionsLanguage() {
        let prompt = CacheEvaluationPrompts.systemSingle(language: .vietnamese)
        XCTAssertTrue(prompt.contains("Vietnamese"),
                      "expected language phrase to be injected into system prompt")
    }

    func testSystemBulkPromptRequiresPerPathEcho() {
        let prompt = CacheEvaluationPrompts.systemBulk(language: .english)
        XCTAssertTrue(prompt.lowercased().contains("verbatim"),
                      "bulk prompt must tell the model to echo each path verbatim")
    }

    func testJSONSchemasAreValidJSON() {
        // The schema strings go straight to `claude --json-schema`; a typo
        // would only surface as a runtime CLI error. Parse them here so a
        // broken schema fails the build's test gate instead.
        for schema in [CacheEvaluationPrompts.singleJSONSchema,
                       CacheEvaluationPrompts.bulkJSONSchema] {
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(schema.utf8)),
                "schema string must be valid JSON"
            )
        }
    }

    func testUserPromptIncludesPathAndHandCuratedHint() {
        let url = URL(fileURLWithPath: "/tmp/cache-x")
        let prompt = CacheEvaluationPrompts.userPrompt(
            path: url,
            displayName: "Cache X",
            handCuratedRisk: .caution
        )
        XCTAssertTrue(prompt.contains("/tmp/cache-x"))
        XCTAssertTrue(prompt.contains("Cache X"))
        XCTAssertTrue(prompt.contains("caution"))
    }

    // MARK: - CLI envelope interpretation

    func testInterpretResultExtractsStructuredOutput() {
        // `--output-format json` envelope with `--json-schema` populated.
        let envelope = #"""
        {"type":"result","subtype":"success","is_error":false,
         "result":"Done.","structured_output":{"safety":"safe","purpose":"p"}}
        """#
        let result = ClaudeCLIRunner.interpretResult(
            stdout: Data(envelope.utf8), stderr: "", exitCode: 0, jsonSchemaUsed: true
        )
        guard case .success(let json) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertTrue(json.contains("\"safety\""))
        XCTAssertTrue(json.contains("\"p\""))
    }

    func testInterpretResultSurfacesCLIReportedError() {
        // The not-logged-in case observed in practice: exit 1, but stdout
        // is still a parseable envelope with is_error=true.
        let envelope = #"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#
        let result = ClaudeCLIRunner.interpretResult(
            stdout: Data(envelope.utf8), stderr: "", exitCode: 1, jsonSchemaUsed: true
        )
        guard case .failure(.cliReportedError(let msg)) = result else {
            return XCTFail("expected .cliReportedError, got \(result)")
        }
        XCTAssertEqual(msg, "Not logged in · Please run /login")
    }

    func testInterpretResultFlagsMissingStructuredOutput() {
        // Schema requested but the envelope has no structured_output.
        let envelope = #"{"type":"result","is_error":false,"result":"hi"}"#
        let result = ClaudeCLIRunner.interpretResult(
            stdout: Data(envelope.utf8), stderr: "", exitCode: 0, jsonSchemaUsed: true
        )
        guard case .failure(.malformedOutput) = result else {
            return XCTFail("expected .malformedOutput, got \(result)")
        }
    }

    func testInterpretResultFlagsNonJSONStdoutOnNonZeroExit() {
        let result = ClaudeCLIRunner.interpretResult(
            stdout: Data("segfault".utf8), stderr: "boom", exitCode: 139, jsonSchemaUsed: true
        )
        guard case .failure(.nonZeroExit(let status, _)) = result else {
            return XCTFail("expected .nonZeroExit, got \(result)")
        }
        XCTAssertEqual(status, 139)
    }

    // MARK: - Single evaluate (happy + error paths)

    func testEvaluateMapsCLIOutputToEvaluation() async {
        let runner = StubCLIRunner(outcome: .success("""
        {"safety": "caution", "warning": "Shared store", "purpose": "pnpm CAS store", "detail": null}
        """))
        let evaluator = CacheEvaluator(cliRunner: runner)
        let row = makeRow(handCurated: .caution, eval: nil)

        let result = await evaluator.evaluate(row: row, model: .sonnet46, language: .english)
        switch result {
        case .success(let eval):
            XCTAssertEqual(eval.safety, .caution)
            XCTAssertEqual(eval.warning, "Shared store")
            XCTAssertEqual(eval.purpose, "pnpm CAS store")
            XCTAssertEqual(eval.modelUsed, AIModelChoice.sonnet46.rawValue)
        case .failure(let err):
            XCTFail("expected success, got \(err)")
        }
    }

    func testEvaluateSurfacesCLINotInstalled() async {
        let runner = StubCLIRunner(outcome: .failure(ClaudeCLIRunner.InvocationError.notInstalled))
        let evaluator = CacheEvaluator(cliRunner: runner)
        let result = await evaluator.evaluate(row: makeRow(handCurated: .safe, eval: nil),
                                              model: .sonnet46, language: .english)
        if case .failure(.cliNotInstalled) = result { return }
        XCTFail("expected .cliNotInstalled, got \(result)")
    }

    func testEvaluateSurfacesCLIReportedErrorAsCliFailed() async {
        // The "Not logged in" path: runner throws .cliReportedError, the
        // evaluator should fold it into .cliFailed for the inline alert.
        let runner = StubCLIRunner(outcome: .failure(
            ClaudeCLIRunner.InvocationError.cliReportedError("Not logged in · Please run /login")
        ))
        let evaluator = CacheEvaluator(cliRunner: runner)
        let result = await evaluator.evaluate(row: makeRow(handCurated: .safe, eval: nil),
                                              model: .sonnet46, language: .english)
        if case .failure(.cliFailed(let msg)) = result {
            XCTAssertEqual(msg, "Not logged in · Please run /login")
            return
        }
        XCTFail("expected .cliFailed, got \(result)")
    }

    func testEvaluateSurfacesParseFailureWhenOutputIsNotJSON() async {
        let runner = StubCLIRunner(outcome: .success("not json at all"))
        let evaluator = CacheEvaluator(cliRunner: runner)
        let result = await evaluator.evaluate(row: makeRow(handCurated: .safe, eval: nil),
                                              model: .sonnet46, language: .english)
        if case .failure(.parseFailed) = result { return }
        XCTFail("expected .parseFailed, got \(result)")
    }

    // MARK: - Bulk evaluate

    func testEvaluateBulkPairsResponseToRowsByPath() async {
        let rowA = makeRow(handCurated: .safe, eval: nil, path: URL(fileURLWithPath: "/tmp/a"))
        let rowB = makeRow(handCurated: .caution, eval: nil, path: URL(fileURLWithPath: "/tmp/b"))
        let cliOutput = """
        {
          "evaluations": [
            {"path": "/tmp/a", "safety": "safe", "warning": null, "purpose": "rebuilds", "detail": null},
            {"path": "/tmp/b", "safety": "risky", "warning": "tokens", "purpose": "user state", "detail": null}
          ]
        }
        """
        let runner = StubCLIRunner(outcome: .success(cliOutput))
        let evaluator = CacheEvaluator(cliRunner: runner)

        let result = await evaluator.evaluateBulk(rows: [rowA, rowB],
                                                  model: .sonnet46,
                                                  language: .english)
        switch result {
        case .success(let byURL):
            XCTAssertEqual(byURL.count, 2)
            XCTAssertEqual(byURL[rowA.path]?.safety, .safe)
            XCTAssertEqual(byURL[rowB.path]?.safety, .risky)
            XCTAssertEqual(byURL[rowB.path]?.warning, "tokens")
        case .failure(let err):
            XCTFail("expected success, got \(err)")
        }
    }

    func testEvaluateBulkSkipsUnknownPathsFromModel() async {
        // Model echoes a path the user never asked about — we drop the
        // entry rather than silently writing to a wrong row.
        let rowA = makeRow(handCurated: .safe, eval: nil, path: URL(fileURLWithPath: "/tmp/a"))
        let cliOutput = #"{"evaluations":[{"path":"/tmp/SOMEWHERE_ELSE","safety":"safe","purpose":"p","warning":null,"detail":null}]}"#
        let runner = StubCLIRunner(outcome: .success(cliOutput))
        let evaluator = CacheEvaluator(cliRunner: runner)

        let result = await evaluator.evaluateBulk(rows: [rowA], model: .sonnet46, language: .english)
        if case .success(let byURL) = result {
            XCTAssertTrue(byURL.isEmpty, "unknown path should not land on any row")
        } else {
            XCTFail("expected success with empty map, got \(result)")
        }
    }

    func testEvaluateBulkOnEmptyRowsReturnsEmptyWithoutInvokingCLI() async {
        // Even a misbehaving CLI shouldn't be touched when there's nothing
        // to evaluate — the early return guards the user's quota.
        let runner = StubCLIRunner(outcome: .failure(ClaudeCLIRunner.InvocationError.notInstalled))
        let evaluator = CacheEvaluator(cliRunner: runner)
        let result = await evaluator.evaluateBulk(rows: [], model: .sonnet46, language: .english)
        if case .success(let byURL) = result {
            XCTAssertTrue(byURL.isEmpty)
        } else {
            XCTFail("expected success(empty), got \(result)")
        }
    }

    func testBulkUserPromptListsEveryRow() {
        let rows: [(String, URL, CachePath.Risk)] = [
            ("Cache A", URL(fileURLWithPath: "/tmp/a"), .safe),
            ("Cache B", URL(fileURLWithPath: "/tmp/b"), .caution)
        ]
        let prompt = CacheEvaluationPrompts.userPromptBulk(rows: rows)
        XCTAssertTrue(prompt.contains("Cache A"))
        XCTAssertTrue(prompt.contains("/tmp/a"))
        XCTAssertTrue(prompt.contains("Cache B"))
        XCTAssertTrue(prompt.contains("/tmp/b"))
    }

    // MARK: - chooseAutoCleanTargets

    func testChooseAutoCleanTargetsSkipsRiskyVerdict() {
        let rowSafe = makeRow(handCurated: .safe, eval: nil, size: 5_000_000_000, auto: true)
        let rowRiskyAI = makeRow(handCurated: .safe, eval: makeEval(safety: .risky), size: 10_000_000_000, auto: true)
        // 6 GB overage — without the risky gate, the bigger 10 GB row would
        // be picked. With the gate, only the 5 GB safe row qualifies.
        let picked = MenuBarViewModel.chooseAutoCleanTargets(
            from: [rowSafe, rowRiskyAI],
            byteOverage: 6_000_000_000
        )
        XCTAssertEqual(picked, [rowSafe.path])
    }

    func testChooseAutoCleanTargetsPicksSmallestSubsetGreedyByLargest() {
        // 4 GB overage. Two safe candidates: 10 GB and 1 GB. Greedy picks
        // the 10 GB one (largest first), stops there — single row covers
        // the overage on its own.
        let big = makeRow(handCurated: .safe, eval: nil, size: 10_000_000_000, auto: true)
        let small = makeRow(handCurated: .safe, eval: nil, size: 1_000_000_000, auto: true)
        let picked = MenuBarViewModel.chooseAutoCleanTargets(
            from: [small, big],
            byteOverage: 4_000_000_000
        )
        XCTAssertEqual(picked, [big.path])
    }

    func testChooseAutoCleanTargetsAccumulatesWhenOneRowInsufficient() {
        // 5 GB overage. Two safe 3 GB rows — need both.
        let a = makeRow(handCurated: .safe, eval: nil, size: 3_000_000_000, auto: true)
        let b = makeRow(handCurated: .safe, eval: nil, size: 3_000_000_000, auto: true)
        let picked = MenuBarViewModel.chooseAutoCleanTargets(
            from: [a, b],
            byteOverage: 5_000_000_000
        )
        XCTAssertEqual(Set(picked), Set([a.path, b.path]))
    }

    func testChooseAutoCleanTargetsReturnsEmptyWhenNoOverage() {
        let row = makeRow(handCurated: .safe, eval: nil, size: 1_000_000_000, auto: true)
        XCTAssertTrue(MenuBarViewModel.chooseAutoCleanTargets(from: [row], byteOverage: 0).isEmpty)
        XCTAssertTrue(MenuBarViewModel.chooseAutoCleanTargets(from: [row], byteOverage: -100).isEmpty)
    }

    func testChooseAutoCleanTargetsSkipsAutoCleanOffRows() {
        let off = makeRow(handCurated: .safe, eval: nil, size: 10_000_000_000, auto: false)
        let on = makeRow(handCurated: .safe, eval: nil, size: 2_000_000_000, auto: true)
        let picked = MenuBarViewModel.chooseAutoCleanTargets(
            from: [off, on],
            byteOverage: 5_000_000_000
        )
        // Even though `off` would cover the overage easily, the toggle
        // gate means only `on` is eligible. Returns full eligible set
        // when it can't fully cover.
        XCTAssertEqual(picked, [on.path])
    }

    // MARK: - Helpers

    private func makeRow(
        handCurated: CachePath.Risk,
        eval: CacheAIEvaluation?,
        size: Int = 0,
        auto: Bool = false,
        path: URL? = nil
    ) -> CachePathRow {
        // Unique path per call (unless caller pins one) so target-selection
        // tests don't get accidental dedup behavior from collisions.
        CachePathRow(
            displayName: "Test",
            path: path ?? URL(fileURLWithPath: "/tmp/test-\(UUID().uuidString)"),
            sizeBytes: size,
            risk: handCurated,
            autoCleanEnabled: auto,
            aiEvaluation: eval
        )
    }

    private func makeEval(safety: CacheAIEvaluation.Safety) -> CacheAIEvaluation {
        CacheAIEvaluation(
            safety: safety,
            warning: nil,
            purpose: "p",
            detail: nil,
            modelUsed: "test-model",
            evaluatedAt: Date()
        )
    }
}
