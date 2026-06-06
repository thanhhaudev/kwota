//
//  AppPaths.swift
//  Kwota
//
//  Single source for on-disk locations under Application Support.
//

import Foundation

enum AppPaths {
    static let bundleId = "com.thanhhaudev.Kwota"

    static var applicationSupportDirectory: URL {
        // `urls(for:in:)` is non-empty in practice, but a hardened sandbox
        // can theoretically return []. Fall back to the temp dir instead of
        // crashing on a force-unwrap.
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(bundleId, isDirectory: true)
    }

    /// Antigravity's per-user globalStorage SQLite file. Lives under the
    /// system Application Support root (NOT Kwota's bundle root). Read-only
    /// consumers should open this with `SQLITE_OPEN_READONLY` and the
    /// `unix-none` VFS so we never block writes that Antigravity is doing.
    static var antigravityGlobalStorageDB: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Antigravity", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb")
    }

    static var profilesFile: URL {
        applicationSupportDirectory.appendingPathComponent("profiles.json")
    }

    static var notificationSettingsFile: URL {
        applicationSupportDirectory.appendingPathComponent("notification-settings.json")
    }

    static func profileDirectory(id: UUID) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func usageHistoryFile(id: UUID) -> URL {
        profileDirectory(id: id).appendingPathComponent("usage-history.json")
    }

    /// Persisted Cache-tab state: settings (cap, interval, language),
    /// AI model choice, AI evaluations keyed by path, custom paths the
    /// user added, per-path auto-clean toggles, and the once-per-path
    /// risky-alert acknowledgements. Single file rather than UserDefaults
    /// because the evaluations dictionary can grow into the 10s of KB —
    /// large enough to be a poor fit for UserDefaults.
    static var cacheStateFile: URL {
        applicationSupportDirectory.appendingPathComponent("cache-state.json")
    }

    /// Persisted last-successful `ProviderUsageSummary` per non-active
    /// switcher row. Hydrated by `ProfileSwitcherFetchCoordinator` on
    /// launch so the switcher renders real data immediately instead of
    /// spinning on every cold start. Chrome fields only — payload is
    /// not persisted (see SwitcherSummaryStore).
    static var switcherSummariesFile: URL {
        applicationSupportDirectory.appendingPathComponent("switcher-summaries.json")
    }
}
