//
//  StatsFormat.swift
//  Kwota
//

import Foundation

/// Compact token formatter ("12.3K", "1.2M", "4.7B", "2.5T").
enum StatsFormat {
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000_000...: return String(format: "%.1fT", Double(n) / 1_000_000_000_000)
        case 1_000_000_000...:     return String(format: "%.1fB", Double(n) / 1_000_000_000)
        case 1_000_000...:         return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:             return String(format: "%.1fK", Double(n) / 1_000)
        default:                   return "\(n)"
        }
    }

    /// Full grouped count for tooltips, e.g. "4,744,000,000". Fixed `,`
    /// grouping (the app's UI is English) so it reads the same everywhere.
    static func full(_ n: Int) -> String {
        grouping.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
