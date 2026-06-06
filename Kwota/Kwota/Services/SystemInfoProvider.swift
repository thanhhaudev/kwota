//
//  SystemInfoProvider.swift
//  Kwota
//

import Foundation

/// One installed piece of a provider's surface — either a CLI binary or a
/// desktop app bundle. Providers expose zero or more of these (Codex /
/// Antigravity ship both a CLI and an app; Claude Code ships only a CLI;
/// `Claude.app` is a separate Anthropic product Kwota does not track). The
/// About card renders one row per component so the user can see exactly what
/// Kwota is reading from.
struct InstalledComponent: Equatable, Identifiable {
    /// Stable slug used as `Identifiable.id` — e.g. `"claude-cli"`,
    /// `"codex-app"`, `"agy"`. Survives a label rename.
    let id: String
    /// Human-readable row label — e.g. `"Claude Code"`, `"Codex.app"`,
    /// `"Antigravity CLI (agy)"`. Shown verbatim on the About card.
    let label: String
    /// Version string from the component itself (probe stdout or
    /// `CFBundleShortVersionString`). The row never substitutes a placeholder
    /// — a missing component is omitted entirely instead.
    let version: String
}

struct SystemSnapshot: Equatable {
    let macOSVersion: String
    let installedComponents: [InstalledComponent]
}

enum SystemInfoProvider {
    static func macOSVersionString(from v: OperatingSystemVersion) -> String {
        "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    @MainActor
    static func snapshot(registry: ProviderRegistry) async -> SystemSnapshot {
        let macOS = macOSVersionString(from: ProcessInfo.processInfo.operatingSystemVersion)

        // Preserve registry order so the card always lists providers in the
        // same sequence (Claude, Codex, Antigravity), with each provider's
        // components rendered in the order the provider returns them
        // (CLI first, app second).
        let providers = registry.all.enumerated().map { ($0.offset, $0.element) }

        let collected: [(Int, [InstalledComponent])] = await withTaskGroup(
            of: (Int, [InstalledComponent]).self
        ) { group in
            for (index, provider) in providers {
                group.addTask { @MainActor in
                    (index, await provider.installedComponents())
                }
            }
            var rows: [(Int, [InstalledComponent])] = []
            for await result in group { rows.append(result) }
            rows.sort { $0.0 < $1.0 }
            return rows
        }

        let components = collected.flatMap { $0.1 }

        return SystemSnapshot(
            macOSVersion: macOS,
            installedComponents: components
        )
    }
}
