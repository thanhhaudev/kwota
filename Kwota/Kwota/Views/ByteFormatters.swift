//
//  ByteFormatters.swift
//  Kwota
//

import Foundation

/// English-locale byte formatters. `ByteCountFormatter`'s default behavior
/// follows the system locale — on a Vietnamese system that renders decimals
/// with commas ("85,86 GB"), conflicting with the rest of the UI which uses
/// the English convention (`,` for thousands, `.` for decimal). Pinning
/// `en_US` keeps every byte size consistent regardless of host locale.
enum ByteFormatters {
    /// Decimal scale — 1 KB = 1000 B. Use for user-visible sizes (Cache tab,
    /// download counts) where SI units match what disk-management apps show.
    static let decimal = ByteCountFormatStyle(
        style: .decimal,
        allowedUnits: .all,
        spellsOutZero: false,
        includesActualByteCount: false,
        locale: Locale(identifier: "en_US")
    )

    /// Binary scale — 1 KB = 1024 B. Use for filesystem-level reporting
    /// (Settings → Data storage) where matching `du`/Finder is preferable.
    static let file = ByteCountFormatStyle(
        style: .file,
        allowedUnits: .all,
        spellsOutZero: false,
        includesActualByteCount: false,
        locale: Locale(identifier: "en_US")
    )
}
