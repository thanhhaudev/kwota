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

    /// Friendly display name for a model id. For `claude-…` ids: strip the
    /// prefix, take the first segment as the model name and re-join the rest as
    /// a dotted version, e.g. "claude-opus-4-8" -> "opus 4.8". `unknown` and any
    /// non-`claude-` id (e.g. future "gpt-5.5") pass through unchanged so later
    /// providers aren't pre-empted.
    static func label(for model: String) -> String {
        guard model != "unknown" else { return "unknown" }
        guard model.hasPrefix("claude-") else { return model }
        let rest = String(model.dropFirst("claude-".count))
        let parts = rest.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard let name = parts.first else { return rest }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? name : "\(name) \(version)"
    }
}
