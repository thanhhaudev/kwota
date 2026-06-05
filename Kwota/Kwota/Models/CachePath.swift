//
//  CachePath.swift
//  Kwota
//

import Foundation

struct CachePath: Identifiable, Equatable {
    let id: URL
    let path: URL
    let displayName: String
    let risk: Risk

    enum Risk: String, Equatable { case safe, caution, risky }

    init(path: URL, displayName: String, risk: Risk) {
        self.id = path
        self.path = path
        self.displayName = displayName
        self.risk = risk
    }

    static func defaults() -> [CachePath] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            // Xcode build artifacts — typically the largest dev cache
            CachePath(
                path: home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
                displayName: "Xcode DerivedData",
                risk: .safe
            ),
            // macOS icon services cache (user-level) — can balloon to many GB
            CachePath(
                path: home.appendingPathComponent("Library/Caches/com.apple.iconservices.store"),
                displayName: "Icon services cache (user)",
                risk: .safe
            ),
            // npm content-addressed cache
            CachePath(
                path: home.appendingPathComponent(".npm/_cacache"),
                displayName: "npm cache",
                risk: .safe
            ),
            // Bun install cache
            CachePath(
                path: home.appendingPathComponent(".bun/install/cache"),
                displayName: "Bun cache",
                risk: .safe
            ),
            // Yarn classic cache
            CachePath(
                path: home.appendingPathComponent("Library/Caches/Yarn"),
                displayName: "Yarn cache",
                risk: .safe
            ),
            // pnpm content-addressed store (shared across projects → caution)
            CachePath(
                path: home.appendingPathComponent("Library/pnpm/store"),
                displayName: "pnpm store",
                risk: .caution
            ),
            // Python pip cache
            CachePath(
                path: home.appendingPathComponent(".cache/pip"),
                displayName: "pip cache",
                risk: .safe
            ),
            // Homebrew downloads
            CachePath(
                path: home.appendingPathComponent("Library/Caches/Homebrew"),
                displayName: "Homebrew downloads",
                risk: .safe
            ),
            // Generic Linux-style ~/.cache for various tools
            CachePath(
                path: home.appendingPathComponent(".cache"),
                displayName: "User cache (~/.cache)",
                risk: .safe
            )
        ]
    }
}
