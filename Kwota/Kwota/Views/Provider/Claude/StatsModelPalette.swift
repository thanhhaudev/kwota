//
//  StatsModelPalette.swift
//  Kwota
//

import SwiftUI

/// Maps raw model ids to stable display labels + colors for Stats charts.
/// Shared across providers. Colors are assigned per *set* of models present in
/// a view (`colorMap`), not per individual model, so every model on screen gets
/// a distinct color instead of two unrelated models colliding on the same hash.
enum StatsModelPalette {
    /// Distinct colors for non-pinned models. Two colors are intentionally
    /// absent: `.orange` is reserved for the Sonnet family (matching the weekly
    /// `PerModelCard` "Sonnet only"), and `.green` is reserved for the chart's
    /// daily-average rule — so no model bar is ever mistaken for the avg line.
    private static let palette: [Color] = [
        .blue, .purple, .teal, .pink, .indigo, .red, .mint, .brown
    ]

    /// Families pinned to a fixed brand color that must match other surfaces.
    /// Only Sonnet is pinned (weekly `PerModelCard` shows "Sonnet only" in
    /// orange). Every other model — including Opus — draws a distinct color from
    /// `palette` so families like "gpt"/"gemini" with many variants don't all
    /// collapse onto one color.
    private static let pinnedFamilyColor: [String: Color] = ["sonnet": .orange]

    /// A color for each model in `models`, distinct within the set. Pinned
    /// families keep their brand color; the rest draw from `palette` in a
    /// deterministic sorted order, so a given set yields the same assignment
    /// across launches and no two models in one provider's view collide. Keyed
    /// by raw model id; the chart and the per-model cards both read this map so
    /// a model's color matches across surfaces.
    static func colorMap(for models: [String]) -> [String: Color] {
        var map: [String: Color] = [:]
        // Pinned brand colors first (all Sonnet versions share orange).
        for model in models {
            if let pinned = pinnedFamilyColor[family(of: model)] {
                map[model] = pinned
            }
        }
        // Remaining models get distinct palette colors. `palette` excludes
        // orange, so nothing collides with a pinned Sonnet.
        let rest = models.filter { map[$0] == nil }.sorted()
        for (index, model) in rest.enumerated() {
            map[model] = palette.isEmpty ? .gray : palette[index % palette.count]
        }
        return map
    }

    /// Model family = first dash-or-space segment after an optional `claude-` prefix.
    /// "claude-sonnet-4-6" -> "sonnet"; "gpt-5.5" -> "gpt"; "Gemini 3.1 Pro (High)" -> "gemini".
    static func family(of model: String) -> String {
        let stripped = model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
        let firstToken = stripped.split(whereSeparator: { $0 == "-" || $0 == " " }).first.map(String.init) ?? stripped
        return firstToken.lowercased()
    }

    /// Friendly display name for a model id. For `claude-…` ids: strip the
    /// prefix, take the first segment as the model name and re-join the rest as
    /// a dotted version, e.g. "claude-opus-4-8" -> "opus 4.8". `unknown` and any
    /// non-`claude-` id (e.g. "gpt-5.5") pass through unchanged so later
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
