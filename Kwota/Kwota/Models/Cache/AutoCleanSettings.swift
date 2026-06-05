//
//  AutoCleanSettings.swift
//  Kwota
//

import Foundation

/// Auto-clean configuration block for Settings → Cache. Persisted via
/// `CachePersistenceStore` (single JSON file at `AppPaths.cacheStateFile`)
/// — UserDefaults was the original plan, swapped to JSON when the
/// evaluations dictionary grew too large to comfortably live there.
struct AutoCleanSettings: Equatable, Codable {
    enum ScanInterval: String, CaseIterable, Identifiable, Codable {
        case fifteenMinutes
        case thirtyMinutes
        case oneHour
        case fourHours

        var id: String { rawValue }

        var seconds: TimeInterval {
            switch self {
            case .fifteenMinutes: return 15 * 60
            case .thirtyMinutes:  return 30 * 60
            case .oneHour:        return 60 * 60
            case .fourHours:      return 4 * 60 * 60
            }
        }

        var label: String {
            switch self {
            case .fifteenMinutes: return "15 min"
            case .thirtyMinutes:  return "30 min"
            case .oneHour:        return "1 hour"
            case .fourHours:      return "4 hours"
            }
        }
    }

    var isEnabled: Bool
    var scanInterval: ScanInterval
    var globalCapBytes: Int
    /// Output language for AI evaluations. Doesn't affect the Swift UI;
    /// only routes through `CacheEvaluationPrompts` into the model request.
    var aiLanguage: CacheAILanguage
    /// Number of days items Kwota moved to Trash linger before being
    /// permanently deleted. `0` disables the sweep entirely (items remain
    /// in Trash until the user empties it manually — the macOS default).
    /// Default is 0 / off so installing Kwota doesn't surprise users with
    /// silent permanent-deletes; they opt in once they understand the
    /// trade-off.
    var autoEmptyTrashAfterDays: Int
    /// When true, cleaning bypasses the Trash entirely — freed files are
    /// deleted outright (`removeItem`) so disk space is reclaimed
    /// immediately. Irreversible. Default `false`; enabling it is gated
    /// behind an explicit confirmation in Settings → Cache. When on,
    /// `autoEmptyTrashAfterDays` is moot (nothing reaches the Trash).
    var deletePermanently: Bool

    static let stubDefault = AutoCleanSettings(
        isEnabled: true,
        scanInterval: .thirtyMinutes,
        globalCapBytes: 60 * 1_000_000_000,  // 60 GB — decimal to match formatter
        aiLanguage: .english,
        autoEmptyTrashAfterDays: 0,
        deletePermanently: false
    )

    // Custom decoder defaults the newer fields so cache-state files written
    // before they existed continue to load cleanly (same forward-compat
    // pattern as `CachePersistedState.sizesByPath`).
    enum CodingKeys: String, CodingKey {
        case isEnabled, scanInterval, globalCapBytes, aiLanguage, autoEmptyTrashAfterDays, deletePermanently
    }

    init(
        isEnabled: Bool,
        scanInterval: ScanInterval,
        globalCapBytes: Int,
        aiLanguage: CacheAILanguage,
        autoEmptyTrashAfterDays: Int,
        deletePermanently: Bool
    ) {
        self.isEnabled = isEnabled
        self.scanInterval = scanInterval
        self.globalCapBytes = globalCapBytes
        self.aiLanguage = aiLanguage
        self.autoEmptyTrashAfterDays = autoEmptyTrashAfterDays
        self.deletePermanently = deletePermanently
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        self.scanInterval = try c.decode(ScanInterval.self, forKey: .scanInterval)
        self.globalCapBytes = try c.decode(Int.self, forKey: .globalCapBytes)
        self.aiLanguage = try c.decode(CacheAILanguage.self, forKey: .aiLanguage)
        self.autoEmptyTrashAfterDays = (try? c.decode(Int.self, forKey: .autoEmptyTrashAfterDays)) ?? 0
        // Defaults to false: an old cache-state file pre-dates this field,
        // and silently inheriting "permanent delete" would be unsafe.
        self.deletePermanently = (try? c.decode(Bool.self, forKey: .deletePermanently)) ?? false
    }

    /// Returns a copy with the named fields replaced. Lets pickers in
    /// Settings → Cache write back through `cacheUpdate(settings:)` without
    /// repeating the full initializer at every call site (a trap when new
    /// fields land — every Picker has to be updated in lockstep).
    func with(
        isEnabled: Bool? = nil,
        scanInterval: ScanInterval? = nil,
        globalCapBytes: Int? = nil,
        aiLanguage: CacheAILanguage? = nil,
        autoEmptyTrashAfterDays: Int? = nil,
        deletePermanently: Bool? = nil
    ) -> AutoCleanSettings {
        AutoCleanSettings(
            isEnabled: isEnabled ?? self.isEnabled,
            scanInterval: scanInterval ?? self.scanInterval,
            globalCapBytes: globalCapBytes ?? self.globalCapBytes,
            aiLanguage: aiLanguage ?? self.aiLanguage,
            autoEmptyTrashAfterDays: autoEmptyTrashAfterDays ?? self.autoEmptyTrashAfterDays,
            deletePermanently: deletePermanently ?? self.deletePermanently
        )
    }
}
