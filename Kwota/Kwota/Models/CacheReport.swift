//
//  CacheReport.swift
//  Kwota
//

import Foundation

struct CacheReport: Equatable {
    struct Entry: Equatable {
        let path: URL
        let exists: Bool
        let fileCount: Int
        let bytes: Int
        /// True when enumeration hit the per-target time budget and stopped
        /// early — `bytes`/`fileCount` are then a floor, not the full size.
        var truncated: Bool = false
    }
    let entries: [Entry]
    var totalBytes: Int { entries.reduce(0) { $0 + $1.bytes } }
    var totalFiles: Int { entries.reduce(0) { $0 + $1.fileCount } }
}

/// Outcome of a `CacheCleaner.clean(targets:)` run. One entry per target
/// regardless of whether the folder existed; `bytesFreed` is the sum of the
/// immediate-children sizes that were successfully moved to Trash.
/// `firstError` captures the first per-child failure (typically a permissions
/// issue) so the UI can surface it without spamming the user once per file.
struct CleanReport: Equatable {
    struct Entry: Equatable {
        let path: URL
        let bytesFreed: Int
        let itemsMoved: Int
        let firstError: String?
        /// URLs the items actually live at after `trashItem` succeeded.
        /// Captured so a follow-up sweep can permanently delete just the
        /// items Kwota itself trashed (the 7-day auto-purge feature),
        /// without touching the rest of the user's Trash.
        let trashedItemURLs: [URL]
    }
    let entries: [Entry]
    var totalBytesFreed: Int { entries.reduce(0) { $0 + $1.bytesFreed } }
    var totalItemsMoved: Int { entries.reduce(0) { $0 + $1.itemsMoved } }
    /// Flattened list across all entries. Convenient for the caller's
    /// persistence layer.
    var allTrashedItemURLs: [URL] { entries.flatMap(\.trashedItemURLs) }
}
