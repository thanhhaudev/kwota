//
//  ByteFormatters+Int.swift
//  Kwota
//

import Foundation

extension Int {
    /// Decimal-base byte string ("12.3 GB") matching `ByteCountFormatter(.file)`
    /// labels. Lives here so Cache-feature views don't each ship their own
    /// `Int64(n).formatted(ByteFormatters.decimal)` helper — five copies of
    /// the same one-liner across the popover was already drifting.
    var formattedBytes: String {
        Int64(self).formatted(ByteFormatters.decimal)
    }
}
