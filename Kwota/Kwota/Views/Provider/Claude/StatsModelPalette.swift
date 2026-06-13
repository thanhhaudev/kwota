//
//  StatsModelPalette.swift
//  Kwota
//

import SwiftUI

/// Maps a raw model id to a stable display label + color for Stats charts.
/// Shared across providers (later plans reuse it). Colors are assigned by a
/// stable hash so the same model keeps its color across renders within a session.
enum StatsModelPalette {
    private static let colors: [Color] = [
        .blue, .purple, .teal, .orange, .pink, .green, .indigo, .red, .mint, .brown
    ]

    static func color(for model: String) -> Color {
        var hasher = Hasher()
        hasher.combine(model)
        let raw = hasher.finalize()
        let idx = colors.isEmpty ? 0 : ((raw % colors.count) + colors.count) % colors.count
        return colors[idx]
    }

    /// Trim provider prefixes for a compact axis/legend label.
    /// "claude-opus-4-8" -> "opus-4-8"; "gpt-5.5" -> "gpt-5.5".
    static func label(for model: String) -> String {
        if model == "unknown" { return "unknown" }
        if let r = model.range(of: "claude-") { return String(model[r.upperBound...]) }
        return model
    }
}
