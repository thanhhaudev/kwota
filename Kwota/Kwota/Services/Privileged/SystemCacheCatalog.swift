//
//  SystemCacheCatalog.swift
//  Kwota
//
//  The fixed, hard-coded set of macOS system caches the privileged helper
//  is allowed to delete. This is the security spine of the privileged-helper
//  feature: the helper accepts *identifiers* from this catalog and never a
//  caller-supplied path, so the attack surface is "which of these N known
//  caches" — never "any path".
//
//  Compiled into BOTH the Kwota app target and the KwotaPrivilegedHelper
//  target. Keep it dependency-free (Foundation only) so it builds in the
//  helper's minimal context.
//

import Foundation

enum SystemCacheCatalog {

    struct Entry: Equatable {
        /// Stable identifier sent over XPC. Never change a published value.
        let identifier: String
        /// Hard-coded absolute path whose contents the helper will clear.
        let path: String
        /// Human-readable name shown in the Cache UI.
        let displayName: String
        /// When true, the helper restarts Finder after clearing this cache
        /// so the icon cache rebuilds.
        let restartsFinder: Bool
    }

    /// On macOS 14+ `/Library` is a firmlink onto the Data volume, so
    /// `/Library/Caches/...` and `/System/Volumes/Data/Library/Caches/...`
    /// resolve to the same directory. We list it once to avoid
    /// double-counting size and double-cleaning.
    static let entries: [Entry] = [
        Entry(
            identifier: "iconservices",
            path: "/Library/Caches/com.apple.iconservices.store",
            displayName: "Icon services cache",
            restartsFinder: true
        )
    ]

    /// Look up an entry by its XPC identifier. Returns nil for any
    /// identifier not in the catalog — the helper treats nil as "reject".
    static func entry(for identifier: String) -> Entry? {
        entries.first { $0.identifier == identifier }
    }

    /// Reverse lookup: is this filesystem URL one of our system caches, and
    /// if so what is its identifier? The app uses this to decide whether a
    /// clean target routes through the privileged helper or `CacheCleaner`.
    static func identifier(for url: URL) -> String? {
        let standardized = url.standardizedFileURL.path
        return entries.first { $0.path == standardized }?.identifier
    }
}
