//
//  CacheEvaluationPrompts.swift
//  Kwota
//
//  Source-of-truth prompts and JSON schemas for the Cache → AI feature.
//  Lives in code (not Settings) so users can't accidentally break the
//  contract — output language is the only knob exposed to the UI.
//
//  We invoke Claude via the `claude -p` headless CLI (see
//  `ClaudeCLIRunner`) with `--json-schema`, which forces the model's
//  answer into a schema-validated `structured_output` object. The prompts
//  here therefore describe *what* to evaluate and the bias rules — the
//  output *shape* is enforced by the schema, not by prose.
//

import Foundation

enum CacheEvaluationPrompts {
    /// Safety-bucket vocabulary shared by the single-path and bulk system
    /// prompts. A single edit here changes the model's bias rules for both.
    private static let buckets = """
    Safety buckets:
    - safe: any tool will rebuild the content on next use (Xcode \
      DerivedData, language-package caches like npm/Yarn/Bun, browser \
      caches, app-specific GPU/shader caches).
    - caution: deletion has knock-on effects worth knowing — shared \
      content-addressable stores that force large re-downloads (pnpm \
      store, Homebrew downloads, Docker overlays), or runtime data that \
      must be quit first (simulator caches, IDE indexes).
    - risky: the folder contains user state, configuration, or original \
      data the user owns (~/Documents, ~/Desktop, profile databases, \
      mail stores, OAuth tokens).
    - unknown: you genuinely cannot tell from the path alone.
    """

    /// Stylistic guidance shared across single + bulk prompts.
    private static let style = """
    Be concise. The user is a developer — skip "consider backing up" \
    boilerplate. For `purpose`, write one sentence. For `detail` (when \
    provided), 2-3 sentences max; you may suggest an alternative command \
    in plain text (e.g., "Run `pnpm store prune` instead.") but never \
    assume Kwota will execute it.
    """

    /// System prompt for a single-row evaluation. The output shape is
    /// enforced by `singleJSONSchema` via `--json-schema`, so this prompt
    /// only carries the task framing and bias rules.
    static func systemSingle(language: CacheAILanguage) -> String {
        """
        You are a macOS power-user assistant evaluating a local cache \
        folder for cleanup safety. Classify the folder the user describes.

        \(buckets)

        \(style)

        Write `purpose`, `warning`, and `detail` in \(language.promptName).
        """
    }

    /// System prompt for a bulk evaluation. Adds the per-path echo +
    /// completeness rules the schema can't express on its own.
    static func systemBulk(language: CacheAILanguage) -> String {
        """
        You are a macOS power-user assistant evaluating local cache \
        folders for cleanup safety. Classify every folder the user lists.

        Produce exactly one evaluation per input folder. Echo each input \
        `path` string verbatim so the caller can match the evaluation \
        back to its row. Never omit a path — if you can't tell from the \
        path alone, use "unknown" for that path's safety.

        \(buckets)

        \(style)

        Write `purpose`, `warning`, and `detail` in \(language.promptName).
        """
    }

    /// User prompt for a single-path evaluation. The hand-curated `risk`
    /// is included as a hint the model can override — the whole point of
    /// the AI pass is to refine those defaults with what's actually on
    /// disk.
    static func userPrompt(path: URL, displayName: String, handCuratedRisk: CachePath.Risk) -> String {
        """
        Evaluate this cache folder:
        - displayName: \(displayName)
        - path: \(path.path)
        - hand-curated risk hint (you may override): \(handCuratedRisk.rawValue)
        """
    }

    /// Bulk user prompt. Lists every pending row in a single message so
    /// the model can answer in one shot. Hand-curated risk hints stay
    /// per-row so the model still has the bias context per folder.
    static func userPromptBulk(rows: [(displayName: String, path: URL, handCuratedRisk: CachePath.Risk)]) -> String {
        let entries = rows.map { row in
            """
            - displayName: \(row.displayName)
              path: \(row.path.path)
              hand-curated risk hint (you may override): \(row.handCuratedRisk.rawValue)
            """
        }.joined(separator: "\n")

        return """
        Evaluate every cache folder below. Produce exactly one entry per \
        input path.

        \(entries)
        """
    }

    // MARK: - JSON schemas (passed to `claude --json-schema`)

    /// Schema for a single-path evaluation. Mirrors `CacheEvaluator`'s
    /// `ParsedSingle`. `safety` is enum-constrained so the model can't
    /// invent a bucket; `warning`/`detail` are nullable.
    static let singleJSONSchema = """
    {
      "type": "object",
      "properties": {
        "safety": { "type": "string", "enum": ["safe", "caution", "risky", "unknown"] },
        "warning": { "type": ["string", "null"] },
        "purpose": { "type": "string" },
        "detail": { "type": ["string", "null"] }
      },
      "required": ["safety", "warning", "purpose", "detail"],
      "additionalProperties": false
    }
    """
    // All keys are listed so OpenAI strict mode (codex --output-schema) accepts
    // the schema; warning/detail stay optional via their nullable types.

    /// Schema for a bulk evaluation. Wraps an `evaluations` array whose
    /// items match the single-path schema plus an echoed `path` field.
    static let bulkJSONSchema = """
    {
      "type": "object",
      "properties": {
        "evaluations": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "path": { "type": "string" },
              "safety": { "type": "string", "enum": ["safe", "caution", "risky", "unknown"] },
              "warning": { "type": ["string", "null"] },
              "purpose": { "type": "string" },
              "detail": { "type": ["string", "null"] }
            },
            "required": ["path", "safety", "warning", "purpose", "detail"],
            "additionalProperties": false
          }
        }
      },
      "required": ["evaluations"],
      "additionalProperties": false
    }
    """
    // All keys are listed so OpenAI strict mode (codex --output-schema)
    // accepts the schema; warning/detail stay optional via their nullable types.
}
