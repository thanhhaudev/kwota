//
//  CacheEvaluator.swift
//  Kwota
//
//  Orchestrates a single cache-path or bulk AI evaluation. Routes the
//  prompt through `ClaudeCLIRunner` (spawning `claude -p`) rather than
//  calling `/v1/messages` directly — Anthropic gates third-party OAuth
//  Bearer access to the messages endpoint, so the only path that
//  consistently works is going through Claude Code's own CLI. The CLI
//  consumes the user's normal subscription quota.
//
//  Structured output is enforced by `--json-schema` (see
//  `CacheEvaluationPrompts.singleJSONSchema` / `bulkJSONSchema`): the
//  runner returns the CLI's validated `structured_output` object, so this
//  layer just decodes a clean JSON string into its types.
//

import Foundation

final class CacheEvaluator {
    let cliRunner: ClaudeCLIInvocation
    /// Generous default — a 15-row bulk on Sonnet, going through the CLI's
    /// multi-turn structured-output loop, can run well past a minute.
    /// Timing out is recoverable: the user just retries.
    let timeout: TimeInterval

    init(cliRunner: ClaudeCLIInvocation, timeout: TimeInterval = 180) {
        self.cliRunner = cliRunner
        self.timeout = timeout
    }

    enum EvaluationError: Error, Equatable {
        /// `claude` binary not found in any candidate location. UI hints
        /// the user to install Claude Code.
        case cliNotInstalled
        /// CLI ran but failed — auth ("Not logged in"), quota, non-zero
        /// exit. Carries the CLI's own message for the inline alert.
        case cliFailed(String)
        /// CLI didn't return within `timeout`. Caller can retry.
        case timeout
        /// CLI returned but the structured output isn't decodable as the
        /// expected shape. Carries a short reason for logging.
        case parseFailed(String)
    }

    // MARK: - Decoded schema shapes

    /// Single-path response. Matches `CacheEvaluationPrompts.singleJSONSchema`.
    private struct ParsedSingle: Decodable {
        let safety: String
        let warning: String?
        let purpose: String
        let detail: String?
    }

    /// Bulk response. The outer object wraps an `evaluations` array; each
    /// entry echoes the input `path` verbatim so we can pair back to rows.
    private struct ParsedBulk: Decodable {
        let evaluations: [Item]
        struct Item: Decodable {
            let path: String
            let safety: String
            let warning: String?
            let purpose: String
            let detail: String?
        }
    }

    // MARK: - Bulk eval

    /// Bulk evaluation in a single CLI round-trip. Returns a map keyed by
    /// the row's `path` so the caller can patch matching rows in place;
    /// paths the model omitted simply aren't present in the dictionary.
    func evaluateBulk(
        rows: [CachePathRow],
        model: AIModelChoice,
        language: CacheAILanguage
    ) async -> Result<[URL: CacheAIEvaluation], EvaluationError> {
        guard !rows.isEmpty else { return .success([:]) }

        let systemPrompt = CacheEvaluationPrompts.systemBulk(language: language)
        let userPrompt = CacheEvaluationPrompts.userPromptBulk(
            rows: rows.map { ($0.displayName, $0.path, $0.risk) }
        )

        let outputResult = await runCLI(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            jsonSchema: CacheEvaluationPrompts.bulkJSONSchema
        )
        switch outputResult {
        case .failure(let err):
            return .failure(err)
        case .success(let output):
            let parsed: ParsedBulk
            do {
                parsed = try Self.decode(ParsedBulk.self, from: output)
            } catch {
                return .failure(.parseFailed(String(describing: error)))
            }

            // {path → CachePathRow} lookup so we can resolve the echoed
            // `path` string back to the row's URL. Match by exact path
            // string — the model is instructed to echo verbatim.
            let rowsByPath: [String: CachePathRow] = Dictionary(uniqueKeysWithValues:
                rows.map { ($0.path.path, $0) }
            )
            let now = Date()
            var out: [URL: CacheAIEvaluation] = [:]
            for item in parsed.evaluations {
                guard let row = rowsByPath[item.path] else {
                    AppLog.shared.log(
                        "CacheEvaluator.bulk: model returned unknown path '\(item.path)' — skipped",
                        level: .warn
                    )
                    continue
                }
                let safety = CacheAIEvaluation.Safety(rawValue: item.safety) ?? .unknown
                out[row.path] = CacheAIEvaluation(
                    safety: safety,
                    warning: item.warning?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    purpose: item.purpose,
                    detail: item.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    modelUsed: model.rawValue,
                    evaluatedAt: now
                )
            }
            return .success(out)
        }
    }

    // MARK: - Single-row eval

    func evaluate(
        row: CachePathRow,
        model: AIModelChoice,
        language: CacheAILanguage
    ) async -> Result<CacheAIEvaluation, EvaluationError> {
        let systemPrompt = CacheEvaluationPrompts.systemSingle(language: language)
        let userPrompt = CacheEvaluationPrompts.userPrompt(
            path: row.path,
            displayName: row.displayName,
            handCuratedRisk: row.risk
        )

        let outputResult = await runCLI(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            jsonSchema: CacheEvaluationPrompts.singleJSONSchema
        )
        switch outputResult {
        case .failure(let err):
            return .failure(err)
        case .success(let output):
            let parsed: ParsedSingle
            do {
                parsed = try Self.decode(ParsedSingle.self, from: output)
            } catch {
                return .failure(.parseFailed(String(describing: error)))
            }
            let safety = CacheAIEvaluation.Safety(rawValue: parsed.safety) ?? .unknown
            let eval = CacheAIEvaluation(
                safety: safety,
                warning: parsed.warning?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                purpose: parsed.purpose,
                detail: parsed.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                modelUsed: model.rawValue,
                evaluatedAt: Date()
            )
            return .success(eval)
        }
    }

    // MARK: - CLI plumbing

    /// Invoke the CLI and normalize its error vocabulary into our own.
    /// Centralizes the catch-block so single + bulk don't duplicate the
    /// same error mapping.
    private func runCLI(
        systemPrompt: String,
        userPrompt: String,
        model: AIModelChoice,
        jsonSchema: String
    ) async -> Result<String, EvaluationError> {
        do {
            let out = try await cliRunner.ask(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: model.rawValue,
                jsonSchema: jsonSchema,
                timeout: timeout
            )
            return .success(out)
        } catch ClaudeCLIRunner.InvocationError.notInstalled {
            return .failure(.cliNotInstalled)
        } catch ClaudeCLIRunner.InvocationError.timeout {
            return .failure(.timeout)
        } catch ClaudeCLIRunner.InvocationError.cliReportedError(let msg) {
            return .failure(.cliFailed(msg))
        } catch ClaudeCLIRunner.InvocationError.nonZeroExit(_, let msg) {
            return .failure(.cliFailed(msg))
        } catch ClaudeCLIRunner.InvocationError.launchFailed(let msg) {
            return .failure(.cliFailed(msg))
        } catch ClaudeCLIRunner.InvocationError.malformedOutput(let msg) {
            return .failure(.parseFailed(msg))
        } catch {
            return .failure(.cliFailed(String(describing: error)))
        }
    }

    /// Decode the runner's `structured_output` JSON string into `T`. The
    /// `--json-schema` flag means the string is already schema-validated,
    /// so this is a plain `JSONDecoder` pass — no fence-stripping or
    /// brace-scanning needed. Visible to tests for direct coverage.
    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "utf8 conversion failed")
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
