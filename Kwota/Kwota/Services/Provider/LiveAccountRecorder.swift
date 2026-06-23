//
//  LiveAccountRecorder.swift
//  Kwota
//
//  Records usage history for live (kind == .auto) accounts that are NOT the
//  active profile, so each provider's Session + Weekly charts stay populated
//  even while the user is viewing a different provider. One fetch per provider
//  per call. Writes go to each profile's own usage-history.json via a
//  short-lived UsageHistoryStore that reloads the file on every append — the
//  same race-free idiom MenuBarViewModel.appendAntigravityGroupHistory uses
//  for non-active Antigravity groups. The recorder only ever writes non-active
//  profiles, so it never races the active path's long-lived historyStore.
//

import Foundation

@MainActor
final class LiveAccountRecorder {
    private let fetcher: any ProfileUsageFetching
    private let historyFile: (UUID) -> URL
    private let now: () -> Date
    private let minRecordInterval: TimeInterval
    private let makeStore: @MainActor (URL) -> UsageHistoryStore

    init(
        fetcher: any ProfileUsageFetching,
        historyFile: @escaping (UUID) -> URL,
        now: @escaping () -> Date = Date.init,
        minRecordInterval: TimeInterval = 45,
        makeStore: @escaping @MainActor (URL) -> UsageHistoryStore = { UsageHistoryStore(historyFile: $0) }
    ) {
        self.fetcher = fetcher
        self.historyFile = historyFile
        self.now = now
        self.minRecordInterval = minRecordInterval
        self.makeStore = makeStore
    }

    /// Fetch `profile` and append a history entry to its own file. Returns
    /// false (no write) when: the provider is in a back-off window; a sample
    /// was recorded within `minRecordInterval`; the fetch throws; the summary
    /// has no bucket data; or `isStillNonActive()` is false after the fetch
    /// (the profile became active mid-fetch — the active path now owns it).
    @discardableResult
    func record(
        profile: Profile,
        backoffUntil: Date?,
        isStillNonActive: () -> Bool
    ) async -> Bool {
        if let until = backoffUntil, until > now() { return false }

        let store = makeStore(historyFile(profile.id))
        let existing: [UsageHistoryEntry]
        do {
            existing = try store.load()
        } catch {
            AppLog.shared.log(
                "LiveAccountRecorder: history load failed for \(profile.id) — skipping to avoid clobbering: \(error)",
                level: .error)
            return false
        }
        if let last = existing.map(\.at).max(),
           now().timeIntervalSince(last) < minRecordInterval {
            return false
        }

        let summary: ProviderUsageSummary
        do {
            summary = try await fetcher.fetch(profile: profile)
        } catch {
            return false
        }

        guard isStillNonActive(), summary.hasBucketData else { return false }

        let entry = UsageHistoryEntry(
            at: summary.fetchedAt,
            fiveHour: summary.primary?.utilization,
            sevenDay: summary.secondary?.utilization
        )
        do {
            try store.append(entry)
            try store.flushPendingWrite()
        } catch {
            AppLog.shared.log(
                "LiveAccountRecorder: history write failed for \(profile.id): \(error)",
                level: .error)
            return false
        }

        if profile.providerID == .antigravity,
           let quota = (summary.payload as? AntigravityUsagePayload)?.quota {
            recordAntigravityGroups(quota: quota, profileID: profile.id, at: summary.fetchedAt)
        }
        return true
    }

    /// Mirror MenuBarViewModel.appendAntigravityGroupHistory for the non-active
    /// path: one entry per group into the sibling usage-history-<key>.json.
    private func recordAntigravityGroups(
        quota: AntigravityQuotaSummary, profileID: UUID, at: Date
    ) {
        let dir = historyFile(profileID).deletingLastPathComponent()
        for (key, entry) in AntigravityGroupHistoryBuilder.entries(from: quota, at: at) {
            let store = makeStore(dir.appendingPathComponent("usage-history-\(key).json"))
            try? store.append(entry)
            try? store.flushPendingWrite()
        }
    }

    /// Resolve and record every non-active live account, one fetch per provider.
    func recordNonActive(
        profiles: [Profile],
        currentActiveID: @escaping () -> UUID?,
        backoffUntil: (ProviderID) -> Date?
    ) async {
        let targets = Self.liveNonActiveProfiles(profiles, activeProfileID: currentActiveID())
        for profile in targets {
            await record(
                profile: profile,
                backoffUntil: backoffUntil(profile.providerID),
                isStillNonActive: { currentActiveID() != profile.id }
            )
        }
    }

    /// One `.auto` profile per provider, excluding the active one. Dedupe by
    /// provider keeps the multiplier bounded at one fetch per provider.
    static func liveNonActiveProfiles(
        _ profiles: [Profile], activeProfileID: UUID?
    ) -> [Profile] {
        var seen = Set<ProviderID>()
        var out: [Profile] = []
        for p in profiles where p.kind == .auto && p.id != activeProfileID {
            if seen.insert(p.providerID).inserted { out.append(p) }
        }
        return out
    }
}

@MainActor
protocol LiveAccountRecording: AnyObject {
    func recordNonActive(
        profiles: [Profile],
        currentActiveID: @escaping () -> UUID?,
        backoffUntil: (ProviderID) -> Date?
    ) async
}

extension LiveAccountRecorder: LiveAccountRecording {}
