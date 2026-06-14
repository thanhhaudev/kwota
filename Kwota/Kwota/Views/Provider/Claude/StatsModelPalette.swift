//
//  StatsModelPalette.swift
//  Kwota
//

import SwiftUI

/// Maps a raw model id to a stable display label + color for Stats charts.
/// Shared across providers (later plans reuse it). Colors are assigned by a
/// deterministic hash so the same model keeps its color across launches and
/// across surfaces (the daily chart and the per-model cards match).
enum StatsModelPalette {
    private static let colors: [Color] = [
        .blue, .purple, .teal, .orange, .pink, .green, .indigo, .red, .mint, .brown
    ]

    /// Brand colors for known Claude model families, matching the app's
    /// existing per-model usage UI (`PerModelCard`: Opus = blue, Sonnet = orange).
    private static let familyColors: [String: Color] = [
        "opus": .blue,
        "sonnet": .orange,
        "haiku": .teal,
        "fable": .pink,
        "gpt": .teal
    ]

    static func color(for model: String) -> Color {
        guard !colors.isEmpty else { return .gray }
        if let fixed = familyColors[family(of: model)] { return fixed }
        // Deterministic FNV-1a hash for unknown families, so a model keeps the
        // SAME color across launches (and matches the per-model cards). Swift's
        // `Hasher` is seeded per-process, which reshuffled colors every run.
        var hash: UInt64 = 1469598103934665603
        for byte in model.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return colors[Int(hash % UInt64(colors.count))]
    }

    /// Model family = first segment after an optional `claude-` prefix.
    /// "claude-sonnet-4-6" -> "sonnet"; "gpt-5.5" -> "gpt".
    static func family(of model: String) -> String {
        let stripped = model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
        return (stripped.split(separator: "-").first.map(String.init) ?? stripped).lowercased()
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
