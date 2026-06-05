//
//  CacheStubData.swift
//  Kwota
//

import Foundation

/// Phase-2 seed rows for the Cache tab. Defines the *shape* of the row
/// list — display name, path, risk, default auto-clean toggle. Both
/// `sizeBytes` and `aiEvaluation` start nil/zero: the real `CacheCleaner`
/// scan patches sizes in by URL once a scan completes, and the bulk AI
/// evaluator (footer AI button) fills `aiEvaluation`. Until then the
/// `sizeBytes > 0` filter hides the row, which puts the popover into its
/// loading state.
enum CacheStubData {

    static func defaultRows() -> [CachePathRow] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base: [CachePathRow] = [
            CachePathRow(
                displayName: "Xcode DerivedData",
                path: home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
                sizeBytes: 0,
                risk: .safe,
                autoCleanEnabled: true
            ),
            CachePathRow(
                displayName: "iOS Simulator caches",
                path: home.appendingPathComponent("Library/Developer/CoreSimulator/Caches"),
                sizeBytes: 0,
                risk: .caution,
                // Default off — Simulator must be quit before clearing or
                // the booted device can end up in an inconsistent state.
                // Conservative default (rule: `.caution` rows ship off, user
                // opts in once they understand the trade-off).
                autoCleanEnabled: false
            ),
            CachePathRow(
                displayName: "JetBrains caches",
                path: home.appendingPathComponent("Library/Caches/JetBrains"),
                sizeBytes: 0,
                risk: .safe,
                autoCleanEnabled: true
            ),
            CachePathRow(
                displayName: "iOS DeviceSupport",
                path: home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport"),
                sizeBytes: 0,
                risk: .safe,
                autoCleanEnabled: true
            ),
            CachePathRow(
                displayName: "pnpm store",
                path: home.appendingPathComponent("Library/pnpm/store"),
                sizeBytes: 0,
                risk: .caution,
                autoCleanEnabled: false
            ),
            CachePathRow(
                displayName: "Xcode app cache",
                path: home.appendingPathComponent("Library/Caches/com.apple.dt.Xcode"),
                sizeBytes: 0,
                risk: .safe,
                autoCleanEnabled: true
            ),
            CachePathRow(
                displayName: "VS Code caches",
                path: home.appendingPathComponent("Library/Application Support/Code/Cache"),
                sizeBytes: 0,
                risk: .safe,
                autoCleanEnabled: true
            ),
            CachePathRow(
                displayName: "Cursor caches",
                path: home.appendingPathComponent("Library/Application Support/Cursor/Cache"),
                sizeBytes: 0,
                risk: .safe,
                autoCleanEnabled: true
            ),
            CachePathRow(
                displayName: "Icon services cache",
                path: home.appendingPathComponent("Library/Caches/com.apple.iconservices.store"),
                sizeBytes: 0,
                risk: .safe,
                autoCleanEnabled: true
            ),
            CachePathRow(
                displayName: "npm cache",
                path: home.appendingPathComponent(".npm/_cacache"),
                sizeBytes: 0,
                risk: .safe,
                autoCleanEnabled: false
            ),
            CachePathRow(
                displayName: "Yarn cache",
                path: home.appendingPathComponent("Library/Caches/Yarn"),
                sizeBytes: 0,
                risk: .safe,
                autoCleanEnabled: false
            ),
            CachePathRow(
                displayName: "Bun cache",
                path: home.appendingPathComponent(".bun/install/cache"),
                sizeBytes: 0,
                risk: .safe,
                autoCleanEnabled: false
            ),
            CachePathRow(
                displayName: "pip cache",
                path: home.appendingPathComponent(".cache/pip"),
                sizeBytes: 0,
                risk: .safe,
                autoCleanEnabled: false
            ),
            CachePathRow(
                displayName: "Homebrew downloads",
                path: home.appendingPathComponent("Library/Caches/Homebrew"),
                sizeBytes: 0,
                risk: .safe,
                autoCleanEnabled: false
            ),
            CachePathRow(
                displayName: "User cache (~/.cache)",
                path: home.appendingPathComponent(".cache"),
                sizeBytes: 0,
                risk: .safe,
                autoCleanEnabled: false
            )
        ]
        return base + systemRows()
    }

    /// One row per `SystemCacheCatalog` entry. These are macOS-owned
    /// caches cleaned through the privileged helper. They ship
    /// auto-clean OFF — the user opts in, and cleaning needs the helper
    /// installed first.
    static func systemRows() -> [CachePathRow] {
        SystemCacheCatalog.entries.map { entry in
            CachePathRow(
                displayName: entry.displayName,
                path: URL(fileURLWithPath: entry.path),
                sizeBytes: 0,
                risk: .safe,
                autoCleanEnabled: false,
                isSystem: true
            )
        }
    }
}
