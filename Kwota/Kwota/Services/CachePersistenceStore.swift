//
//  CachePersistenceStore.swift
//  Kwota
//
//  Load/save the persistent Cache-tab state (settings, AI evaluations,
//  custom paths, per-path toggles, risky-alert acks). Writes are
//  synchronous-on-mutation rather than debounced — the file is small
//  enough (typically <10 KB), and synchronous keeps the model simple:
//  no "did the save flush before quit" worry.
//
//  Writes go through a temp-then-rename to avoid leaving a half-written
//  file if the app crashes mid-encode.
//

import Foundation

/// Snapshot of everything we persist for the Cache tab. Built from
/// `MenuBarViewModel.cacheState` before writing, then re-applied to
/// `cacheState` on load.
struct CachePersistedState: Codable, Equatable {
    var settings: AutoCleanSettings
    var aiModel: AIModelChoice
    /// Which CLI engine runs evaluations. Added after `aiModel`; decode
    /// defaults to `.claude` so pre-engine blobs keep loading.
    var aiEngine: CacheAIEngine
    /// Model used when `aiEngine == .codex`. Kept separate from `aiModel`
    /// so switching engines round-trips without losing either choice.
    var aiCodexModel: CodexModelChoice
    /// AI evaluations keyed by `URL.path` string. Decoupled from
    /// `CachePathRow.id` (which is a transient UUID generated on each
    /// process launch) so a row regenerated next launch picks up its old
    /// evaluation by matching path.
    var aiEvaluationsByPath: [String: CacheAIEvaluation]
    /// Custom paths the user added via "Add custom path…". These are NOT
    /// part of `CacheStubData.defaultRows()`, so they have to be
    /// reconstituted on load and merged into the row list.
    var customPaths: [CustomPath]
    /// Per-path auto-clean toggle. Keyed by `URL.path`. Both default and
    /// custom rows persist here so the toggle survives across launches.
    var autoCleanByPath: [String: Bool]
    /// Path strings the user has already been alerted about as risky.
    /// Once-per-path semantics across launches.
    var riskyAlertedPaths: [String]
    /// Last known size in bytes, keyed by `URL.path`. Loaded on launch so
    /// the popover renders stale-but-accurate sizes immediately instead of
    /// showing the loading state every time. The next `cacheScan` refreshes
    /// in the background; rows that no longer exist on disk drop to
    /// `exists = false` after the scan, regardless of what we persisted.
    var sizesByPath: [String: Int]
    /// Items Kwota has moved to ~/.Trash, with the original source path
    /// and the timestamp of the trash move. Powers the optional 7-day
    /// auto-purge — when `settings.autoEmptyTrashAfterDays > 0`, the
    /// scheduler permanent-deletes items whose `trashedAt` is older than
    /// that threshold. Items the user already manually emptied or restored
    /// are simply missing from the Trash location at sweep time; that's a
    /// benign no-op.
    var trashedItems: [TrashedItem]
    /// `URL.path` strings of built-in rows (seeded defaults + catalog system
    /// caches) the user removed from tracking. The hydration re-seed skips any
    /// seeded row whose path is in this set, so a removal survives relaunch.
    /// Custom and user-added system rows aren't tombstoned — they persist
    /// positively in `customPaths`, so removing them just drops them there.
    var removedDefaultPaths: [String]

    struct TrashedItem: Codable, Equatable {
        /// Where the item used to live (e.g.
        /// `/Users/x/Library/Caches/Yarn/v6/abc`).
        let originalPath: String
        /// Current path in ~/.Trash. May not exist anymore if the user
        /// manually emptied or restored; the sweep checks before deleting.
        let trashedURLPath: String
        let trashedAt: Date
    }

    struct CustomPath: Codable, Equatable {
        let urlPath: String
        let displayName: String
        /// True for a user-added system-scope path (outside `$HOME`). Such a
        /// row reconstitutes as `isSystem && isCustom` — tracking-only. Absent
        /// in blobs written before this field existed; defaults to false.
        let isSystem: Bool

        init(urlPath: String, displayName: String, isSystem: Bool = false) {
            self.urlPath = urlPath
            self.displayName = displayName
            self.isSystem = isSystem
        }

        enum CodingKeys: String, CodingKey {
            case urlPath, displayName, isSystem
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.urlPath = try c.decode(String.self, forKey: .urlPath)
            self.displayName = try c.decode(String.self, forKey: .displayName)
            self.isSystem = (try? c.decode(Bool.self, forKey: .isSystem)) ?? false
        }
    }

    // Manual init/encode mirror the auto-synthesized version, except
    // `init(from:)` defaults missing optional-ish fields (`sizesByPath`
    // added late) to empty rather than throwing. Without this, upgrading
    // from a build that didn't persist sizes would wipe the user's
    // settings + evaluations on first launch.
    enum CodingKeys: String, CodingKey {
        case settings, aiModel, aiEngine, aiCodexModel
        case aiEvaluationsByPath, customPaths
        case autoCleanByPath, riskyAlertedPaths, sizesByPath, trashedItems
        case removedDefaultPaths
    }

    init(
        settings: AutoCleanSettings,
        aiModel: AIModelChoice,
        aiEngine: CacheAIEngine = .default,
        aiCodexModel: CodexModelChoice = .default,
        aiEvaluationsByPath: [String: CacheAIEvaluation],
        customPaths: [CustomPath],
        autoCleanByPath: [String: Bool],
        riskyAlertedPaths: [String],
        sizesByPath: [String: Int],
        trashedItems: [TrashedItem],
        removedDefaultPaths: [String] = []
    ) {
        self.settings = settings
        self.aiModel = aiModel
        self.aiEngine = aiEngine
        self.aiCodexModel = aiCodexModel
        self.aiEvaluationsByPath = aiEvaluationsByPath
        self.customPaths = customPaths
        self.autoCleanByPath = autoCleanByPath
        self.riskyAlertedPaths = riskyAlertedPaths
        self.sizesByPath = sizesByPath
        self.trashedItems = trashedItems
        self.removedDefaultPaths = removedDefaultPaths
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.settings = try c.decode(AutoCleanSettings.self, forKey: .settings)
        self.aiModel = try c.decode(AIModelChoice.self, forKey: .aiModel)
        self.aiEngine = (try? c.decode(CacheAIEngine.self, forKey: .aiEngine)) ?? .default
        self.aiCodexModel = (try? c.decode(CodexModelChoice.self, forKey: .aiCodexModel)) ?? .default
        self.aiEvaluationsByPath = try c.decode([String: CacheAIEvaluation].self, forKey: .aiEvaluationsByPath)
        self.customPaths = try c.decode([CustomPath].self, forKey: .customPaths)
        self.autoCleanByPath = try c.decode([String: Bool].self, forKey: .autoCleanByPath)
        self.riskyAlertedPaths = try c.decode([String].self, forKey: .riskyAlertedPaths)
        self.sizesByPath = (try? c.decode([String: Int].self, forKey: .sizesByPath)) ?? [:]
        self.trashedItems = (try? c.decode([TrashedItem].self, forKey: .trashedItems)) ?? []
        self.removedDefaultPaths = (try? c.decode([String].self, forKey: .removedDefaultPaths)) ?? []
    }

    /// Default state for a fresh install: stub settings, no evaluations,
    /// no custom paths, no toggles overridden. Used when the file is
    /// missing or fails to decode.
    static let initial = CachePersistedState(
        settings: .stubDefault,
        aiModel: .default,
        aiEvaluationsByPath: [:],
        customPaths: [],
        autoCleanByPath: [:],
        riskyAlertedPaths: [],
        sizesByPath: [:],
        trashedItems: []
    )
}

final class CachePersistenceStore {
    let url: URL
    let fm: FileManager

    init(url: URL = AppPaths.cacheStateFile, fileManager: FileManager = .default) {
        self.url = url
        self.fm = fileManager
    }

    /// Read the persisted state. Missing file or any decode error → return
    /// `.initial` (treat as fresh install). We deliberately don't surface
    /// "corrupt file" to the UI: cache state is a convenience layer, not a
    /// source of truth, and a partial state is worse than starting over.
    func load() -> CachePersistedState {
        guard fm.fileExists(atPath: url.path) else {
            return .initial
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CachePersistedState.self, from: data)
        } catch {
            AppLog.shared.log(
                "CachePersistenceStore.load failed at \(url.path): \(error) — falling back to initial",
                level: .warn
            )
            return .initial
        }
    }

    /// Atomic-ish save: write to a sibling temp file, then rename over the
    /// target. If the process crashes mid-encode the temp file is orphaned
    /// (FileManager cleans these eventually) but the original file is
    /// untouched.
    func save(_ state: CachePersistedState) {
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: url.path) {
                // Let failures here propagate to the outer `catch` so they
                // get logged. Previously `try?` discarded both the result
                // and the error — a partial replace would leave the user
                // with stale data silently.
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            AppLog.shared.log(
                "CachePersistenceStore.save failed at \(url.path): \(error)",
                level: .warn
            )
        }
    }
}
