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

/// Test double for `AgentCLIInvocation`. Either returns a canned
/// `CLIAnswer` or throws a canned error — covers the `EvaluationError`
/// paths plus the happy path without spawning a subprocess.
private final class StubCLIRunner: AgentCLIInvocation, @unchecked Sendable {
    enum Outcome {
        case success(CLIAnswer)
        case failure(Error)
    }
    var outcome: Outcome

    init(outcome: Outcome) { self.outcome = outcome }

    /// Convenience: most tests only care about the output JSON string.
    convenience init(json: String, resolvedModel: String? = nil) {
        self.init(outcome: .success(CLIAnswer(output: json, resolvedModel: resolvedModel)))
    }

    func ask(
        systemPrompt: String,
        userPrompt: String,
        model: String?,
        jsonSchema: String?,
        timeout: TimeInterval
    ) async throws -> CLIAnswer {
        switch outcome {
        case .success(let answer): return answer
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

    func testJSONSchemasMarkEveryPropertyRequired() throws {
        // OpenAI strict structured-output (codex --output-schema) rejects a
        // schema unless `required` lists every key in `properties`;
        // optionality must come from nullable types, not omission. Both
        // schemas must satisfy this so the Codex engine doesn't 400.
        func assertAllPropsRequired(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            // Walk to the object that actually carries properties: the single
            // schema is the root; the bulk schema nests under
            // properties.evaluations.items.
            func check(_ node: [String: Any]) {
                guard let props = node["properties"] as? [String: Any] else { return }
                let required = Set((node["required"] as? [String]) ?? [])
                XCTAssertEqual(required, Set(props.keys),
                               "every property must be in `required` for OpenAI strict mode", file: file, line: line)
            }
            check(obj)
            if let props = obj["properties"] as? [String: Any],
               let evals = props["evaluations"] as? [String: Any],
               let items = evals["items"] as? [String: Any] {
                check(items)
            }
        }
        try assertAllPropsRequired(CacheEvaluationPrompts.singleJSONSchema)
        try assertAllPropsRequired(CacheEvaluationPrompts.bulkJSONSchema)
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
        guard case .success(let answer) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertTrue(answer.output.contains("\"safety\""))
        XCTAssertTrue(answer.output.contains("\"p\""))
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

    func testInterpretResultExtractsResolvedModelFromModelUsage() {
        let envelope = #"""
        {"is_error":false,"structured_output":{"safety":"safe","purpose":"p"},
         "modelUsage":{"claude-opus-4-8":{"outputTokens":4}}}
        """#
        let result = ClaudeCLIRunner.interpretResult(
            stdout: Data(envelope.utf8), stderr: "", exitCode: 0, jsonSchemaUsed: true
        )
        guard case .success(let answer) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(answer.resolvedModel, "claude-opus-4-8")
        XCTAssertTrue(answer.output.contains("\"safety\""))
    }

    func testInterpretResultPicksHighestOutputTokenModelOnFallback() {
        let envelope = #"""
        {"is_error":false,"structured_output":{"safety":"safe","purpose":"p"},
         "modelUsage":{"claude-haiku-4-5":{"outputTokens":1},
                       "claude-opus-4-8":{"outputTokens":50}}}
        """#
        let result = ClaudeCLIRunner.interpretResult(
            stdout: Data(envelope.utf8), stderr: "", exitCode: 0, jsonSchemaUsed: true
        )
        guard case .success(let answer) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(answer.resolvedModel, "claude-opus-4-8")
    }

    func testInterpretResultResolvedModelNilWhenNoModelUsage() {
        let envelope = #"{"is_error":false,"structured_output":{"safety":"safe","purpose":"p"}}"#
        let result = ClaudeCLIRunner.interpretResult(
            stdout: Data(envelope.utf8), stderr: "", exitCode: 0, jsonSchemaUsed: true
        )
        guard case .success(let answer) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertNil(answer.resolvedModel)
    }

    // MARK: - Single evaluate (happy + error paths)

    func testEvaluateMapsCLIOutputToEvaluation() async {
        let runner = StubCLIRunner(json: """
        {"safety": "caution", "warning": "Shared store", "purpose": "pnpm CAS store", "detail": null}
        """)
        let evaluator = CacheEvaluator(cliRunner: runner)
        let row = makeRow(handCurated: .caution, eval: nil)

        let result = await evaluator.evaluate(
            row: row,
            model: AIModelChoice.sonnet.rawValue,
            modelLabel: AIModelChoice.sonnet.rawValue,
            language: .english
        )
        switch result {
        case .success(let eval):
            XCTAssertEqual(eval.safety, .caution)
            XCTAssertEqual(eval.warning, "Shared store")
            XCTAssertEqual(eval.purpose, "pnpm CAS store")
            XCTAssertEqual(eval.modelUsed, AIModelChoice.sonnet.rawValue)
        case .failure(let err):
            XCTFail("expected success, got \(err)")
        }
    }

    func testEvaluateSurfacesCLINotInstalled() async {
        let runner = StubCLIRunner(outcome: .failure(CLIInvocationError.notInstalled))
        let evaluator = CacheEvaluator(cliRunner: runner)
        let result = await evaluator.evaluate(
            row: makeRow(handCurated: .safe, eval: nil),
            model: AIModelChoice.sonnet.rawValue,
            modelLabel: AIModelChoice.sonnet.rawValue,
            language: .english
        )
        if case .failure(.cliNotInstalled) = result { return }
        XCTFail("expected .cliNotInstalled, got \(result)")
    }

    func testEvaluateSurfacesCLIReportedErrorAsCliFailed() async {
        // The "Not logged in" path: runner throws .cliReportedError, the
        // evaluator should fold it into .cliFailed for the inline alert.
        let runner = StubCLIRunner(outcome: .failure(
            CLIInvocationError.cliReportedError("Not logged in · Please run /login")
        ))
        let evaluator = CacheEvaluator(cliRunner: runner)
        let result = await evaluator.evaluate(
            row: makeRow(handCurated: .safe, eval: nil),
            model: AIModelChoice.sonnet.rawValue,
            modelLabel: AIModelChoice.sonnet.rawValue,
            language: .english
        )
        if case .failure(.cliFailed(let msg)) = result {
            XCTAssertEqual(msg, "Not logged in · Please run /login")
            return
        }
        XCTFail("expected .cliFailed, got \(result)")
    }

    func testEvaluateSurfacesParseFailureWhenOutputIsNotJSON() async {
        let runner = StubCLIRunner(json: "not json at all")
        let evaluator = CacheEvaluator(cliRunner: runner)
        let result = await evaluator.evaluate(
            row: makeRow(handCurated: .safe, eval: nil),
            model: AIModelChoice.sonnet.rawValue,
            modelLabel: AIModelChoice.sonnet.rawValue,
            language: .english
        )
        if case .failure(.parseFailed) = result { return }
        XCTFail("expected .parseFailed, got \(result)")
    }

    func testEvaluateStampsModelLabelNotModelArg() async {
        // Codex-default: nil model arg (engine decides) but a stable label
        // for provenance. The two must not be conflated.
        let runner = StubCLIRunner(json:
            #"{"safety": "safe", "warning": null, "purpose": "p", "detail": null}"#
        )
        let evaluator = CacheEvaluator(cliRunner: runner)
        let result = await evaluator.evaluate(
            row: makeRow(handCurated: .safe, eval: nil),
            model: nil,
            modelLabel: "codex-default",
            language: .english
        )
        guard case .success(let eval) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(eval.modelUsed, "codex-default")
    }

    func testEvaluateStampsResolvedModelOverLabelWhenPresent() async {
        // Claude alias path: label is "opus" but the envelope reported the
        // resolved version — provenance must show the real version.
        let runner = StubCLIRunner(
            json: #"{"safety":"safe","warning":null,"purpose":"p","detail":null}"#,
            resolvedModel: "claude-opus-4-8"
        )
        let evaluator = CacheEvaluator(cliRunner: runner)
        let result = await evaluator.evaluate(
            row: makeRow(handCurated: .safe, eval: nil),
            model: "opus",
            modelLabel: "opus",
            language: .english
        )
        guard case .success(let eval) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(eval.modelUsed, "claude-opus-4-8",
                       "resolved model from the envelope wins over the alias label")
    }

    func testEvaluateFallsBackToLabelWhenNoResolvedModel() async {
        // Codex path: no resolved model → stamp the label.
        let runner = StubCLIRunner(
            json: #"{"safety":"safe","warning":null,"purpose":"p","detail":null}"#,
            resolvedModel: nil
        )
        let evaluator = CacheEvaluator(cliRunner: runner)
        let result = await evaluator.evaluate(
            row: makeRow(handCurated: .safe, eval: nil),
            model: nil,
            modelLabel: "codex-default",
            language: .english
        )
        guard case .success(let eval) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(eval.modelUsed, "codex-default")
    }

    func testEvaluationModelSelectionAntigravity() {
        let agy = MenuBarViewModel.evaluationModelSelection(
            engine: .antigravity, claudeModel: .haiku, codexModel: .codexDefault
        )
        XCTAssertNil(agy.model, "agy has no --model")
        XCTAssertEqual(agy.label, "antigravity")
    }

    func testEvaluationModelSelectionMapsEngineToArgs() {
        // Claude: model arg and label are both the Anthropic ID.
        let claude = MenuBarViewModel.evaluationModelSelection(
            engine: .claude, claudeModel: .haiku, codexModel: .gpt54Mini
        )
        XCTAssertEqual(claude.model, AIModelChoice.haiku.rawValue)
        XCTAssertEqual(claude.label, AIModelChoice.haiku.rawValue)

        // Codex explicit: slug for both.
        let codex = MenuBarViewModel.evaluationModelSelection(
            engine: .codex, claudeModel: .haiku, codexModel: .gpt54Mini
        )
        XCTAssertEqual(codex.model, "gpt-5.4-mini")
        XCTAssertEqual(codex.label, "gpt-5.4-mini")

        // Codex default: nil arg (CLI config decides), placeholder label.
        let codexDefault = MenuBarViewModel.evaluationModelSelection(
            engine: .codex, claudeModel: .haiku, codexModel: .codexDefault
        )
        XCTAssertNil(codexDefault.model)
        XCTAssertEqual(codexDefault.label, "codex-default")
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
        let runner = StubCLIRunner(json: cliOutput)
        let evaluator = CacheEvaluator(cliRunner: runner)

        let result = await evaluator.evaluateBulk(
            rows: [rowA, rowB],
            model: AIModelChoice.sonnet.rawValue,
            modelLabel: AIModelChoice.sonnet.rawValue,
            language: .english
        )
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
        let runner = StubCLIRunner(json: cliOutput)
        let evaluator = CacheEvaluator(cliRunner: runner)

        let result = await evaluator.evaluateBulk(
            rows: [rowA],
            model: AIModelChoice.sonnet.rawValue,
            modelLabel: AIModelChoice.sonnet.rawValue,
            language: .english
        )
        if case .success(let byURL) = result {
            XCTAssertTrue(byURL.isEmpty, "unknown path should not land on any row")
        } else {
            XCTFail("expected success with empty map, got \(result)")
        }
    }

    func testEvaluateBulkOnEmptyRowsReturnsEmptyWithoutInvokingCLI() async {
        // Even a misbehaving CLI shouldn't be touched when there's nothing
        // to evaluate — the early return guards the user's quota.
        let runner = StubCLIRunner(outcome: .failure(CLIInvocationError.notInstalled))
        let evaluator = CacheEvaluator(cliRunner: runner)
        let result = await evaluator.evaluateBulk(
            rows: [],
            model: AIModelChoice.sonnet.rawValue,
            modelLabel: AIModelChoice.sonnet.rawValue,
            language: .english
        )
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
