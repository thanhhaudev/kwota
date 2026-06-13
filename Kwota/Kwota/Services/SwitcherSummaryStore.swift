//
//  SwitcherSummaryStore.swift
//  Kwota
//
//  Persists the chrome-visible portion of `ProviderUsageSummary` per
//  switcher row to a single JSON file under Application Support.
//  Hydrated by `ProfileSwitcherFetchCoordinator` on init so non-active
//  rows render real data immediately on cold start.
//
//  Why chrome-only: `ProviderUsageSummary.payload` is `any Sendable`
//  and not Codable. The switcher view binds only `primary?.utilization`
//  and `secondary?.utilization`; the per-model chart (which reads the
//  full payload) lives on the active card, not on switcher rows. So
//  we drop `payload` at the encode step and substitute `EmptyPayload`
//  on decode — switcher rendering is unaffected.
//
//  Forward-compat: unknown `providerID` raw values decode as `.claude`
//  (see `ProviderID`).
//

import Foundation

protocol SwitcherSummaryStoring: Sendable {
    func load() -> [UUID: ProviderUsageSummary]
    func save(_ map: [UUID: ProviderUsageSummary])
}

/// Placeholder payload for hydrated `ProviderUsageSummary` values. The
/// switcher never reads `summary.payload`, but the type system requires
/// a non-nil `any Sendable` to construct a `ProviderUsageSummary`.
struct EmptyPayload: Sendable {}

/// On-disk envelope. Encodes only the chrome fields the switcher row
/// renders; `payload` is intentionally absent for providers whose
/// chrome doesn't depend on it.
///
/// Antigravity is an exception: its switcher chrome (AI Credits bar dim
/// state + tooltip overage suffix) reads `overagesEnabled` off the
/// payload, so the envelope persists that one bool alongside the chrome
/// fields and rehydrates a minimal `AntigravityUsageSnapshot` as the
/// payload. Worst-model / wallet aren't persisted — they require fresh
/// data, and the tooltip code already degrades gracefully when they're
/// nil. The overage state survives because it's a stable user
/// preference, not a per-fetch reading.
private struct PersistedSwitcherSummary: Codable {
    let providerID: ProviderID
    let fetchedAt: Date
    let primary: UsageBucket?
    let secondary: UsageBucket?
    let retryAfter: TimeInterval?
    /// Antigravity-only. `nil` for other providers and for older entries
    /// written before this field existed (decoded via decodeIfPresent so
    /// old files load without error).
    let antigravityOveragesEnabled: Bool?

    init(from summary: ProviderUsageSummary) {
        self.providerID = summary.providerID
        self.fetchedAt = summary.fetchedAt
        self.primary = summary.primary
        self.secondary = summary.secondary
        self.retryAfter = summary.retryAfter
        self.antigravityOveragesEnabled =
            (summary.payload as? AntigravityUsagePayload)?.snapshot.overagesEnabled
    }

    /// Reconstructs the in-memory `ProviderUsageSummary` from the persisted
    /// form. Optional return type is preserved for call-site stability even
    /// though every known `providerID` produces a value today.
    func toSummary() -> ProviderUsageSummary? {
        let payload: any Sendable
        if providerID == .antigravity {
            // Minimal snapshot carrying only the persisted overage state
            // so AntigravityProvider's switcherBarTooltips/Dimming hooks
            // read the right value off a cold-start row. Models / wallet
            // stay nil — the tooltip already degrades to "no model rate
            // limits reported" in that case, and the dim flag depends
            // only on overagesEnabled.
            payload = AntigravityUsagePayload(
                snapshot: AntigravityUsageSnapshot(
                    fetchedAt: fetchedAt,
                    overagesEnabled: antigravityOveragesEnabled),
                quota: nil)
        } else {
            payload = EmptyPayload()
        }
        return ProviderUsageSummary(
            providerID: providerID,
            fetchedAt: fetchedAt,
            primary: primary,
            secondary: secondary,
            payload: payload,
            retryAfter: retryAfter
        )
    }
}

private struct PersistedSwitcherSummariesFile: Codable {
    let entries: [String: PersistedSwitcherSummary]
}

final class SwitcherSummaryStore: SwitcherSummaryStoring {
    let fileURL: URL

    init(fileURL: URL = AppPaths.switcherSummariesFile) {
        self.fileURL = fileURL
    }

    func load() -> [UUID: ProviderUsageSummary] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        guard let file = try? decoder.decode(PersistedSwitcherSummariesFile.self, from: data) else {
            AppLog.shared.log(
                "SwitcherSummaryStore.load: failed to decode \(fileURL.lastPathComponent), starting empty",
                level: .warn
            )
            return [:]
        }
        var out: [UUID: ProviderUsageSummary] = [:]
        for (key, entry) in file.entries {
            guard let id = UUID(uuidString: key) else { continue }
            guard let summary = entry.toSummary() else { continue }
            out[id] = summary
        }
        return out
    }

    func save(_ map: [UUID: ProviderUsageSummary]) {
        let entries = Dictionary(uniqueKeysWithValues: map.map { (key, value) in
            (key.uuidString, PersistedSwitcherSummary(from: value))
        })
        let file = PersistedSwitcherSummariesFile(entries: entries)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.shared.log(
                "SwitcherSummaryStore.save: write failed — \(error.localizedDescription)",
                level: .warn
            )
        }
    }
}
