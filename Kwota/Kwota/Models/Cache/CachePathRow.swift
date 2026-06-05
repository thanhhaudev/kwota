//
//  CachePathRow.swift
//  Kwota
//

import Foundation

/// Row model for the Cache tab. Row list is seeded from
/// `CacheStubData.defaultRows()` (which now defines only shape — name, path,
/// risk, default toggle). `sizeBytes`/`exists` get patched in by the real
/// `CacheCleaner.scan` on first popover open; `aiEvaluation` by the AI
/// evaluator. Custom rows the user adds get appended to the same list.
struct CachePathRow: Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var path: URL
    var sizeBytes: Int
    var risk: CachePath.Risk
    var autoCleanEnabled: Bool
    var exists: Bool
    var isCustom: Bool
    /// True for system-scope caches (path outside the user's home). Two
    /// flavours: built-in catalog caches (`isSystem && !isCustom`, cleaned via
    /// `PrivilegedHelperManager`) and user-added system paths
    /// (`isSystem && isCustom`, tracking-only — see `isCleanable`). System rows
    /// are skipped by AI evaluation.
    var isSystem: Bool
    /// Most-recent LLM judgement for this path. nil until the user runs
    /// either bulk-evaluate or per-row Re-evaluate. Phase 2 persists this
    /// across launches.
    var aiEvaluation: CacheAIEvaluation?

    init(
        id: UUID = UUID(),
        displayName: String,
        path: URL,
        sizeBytes: Int,
        risk: CachePath.Risk,
        autoCleanEnabled: Bool,
        exists: Bool = true,
        isCustom: Bool = false,
        isSystem: Bool = false,
        aiEvaluation: CacheAIEvaluation? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.sizeBytes = sizeBytes
        self.risk = risk
        self.autoCleanEnabled = autoCleanEnabled
        self.exists = exists
        self.isCustom = isCustom
        self.isSystem = isSystem
        self.aiEvaluation = aiEvaluation
    }

    /// Risk level to render in the UI (chip + sparkles annotation). The AI
    /// verdict wins when an evaluation exists — the hand-curated `risk` is
    /// only used as a bootstrap so the row has a sensible chip before the
    /// LLM is asked. `unknown` AI verdicts fall back to the hand-curated
    /// hint rather than showing a question-mark chip.
    var effectiveRisk: CachePath.Risk {
        guard let eval = aiEvaluation else { return risk }
        switch eval.safety {
        case .safe:    return .safe
        case .caution: return .caution
        case .risky:   return .risky
        case .unknown: return risk
        }
    }

    /// Whether Kwota can clear this row's contents. A user-added system path
    /// (`isSystem && isCustom`) is tracking-only: the privileged helper accepts
    /// only `SystemCacheCatalog` identifiers, never a caller-supplied path, and
    /// the unprivileged `CacheCleaner` can't touch root-owned directories — so
    /// such a row exposes no Clean affordance. Catalog caches
    /// (`isSystem && !isCustom`), custom folders (`!isSystem && isCustom`), and
    /// defaults all remain cleanable.
    var isCleanable: Bool { !(isSystem && isCustom) }

    /// Display names that appear on BOTH a system row and a non-system row.
    /// A user-scope cache can share its name with a machine-wide one (e.g.
    /// the icon-services cache lives at `~/Library/Caches/...` and
    /// `/Library/Caches/...`), leaving the two rows indistinguishable once
    /// the `(system)`/`(user)` suffixes are dropped. The views add a `user`
    /// pill to the non-system row of any such pair so the scope reads
    /// clearly; when there's no collision the user row needs no marker.
    static func scopeCollisionNames(in rows: [CachePathRow]) -> Set<String> {
        let systemNames = Set(rows.filter { $0.isSystem }.map(\.displayName))
        let userNames = Set(rows.filter { !$0.isSystem }.map(\.displayName))
        return systemNames.intersection(userNames)
    }
}
