//
//  StatsFormat.swift
//  Kwota
//

import Foundation

/// Compact token formatter ("12.3K", "1.2M").
enum StatsFormat {
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.1fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
}
