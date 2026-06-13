//
//  ProfileSwitcherFetchCoordinator.swift
//  Kwota
//
//  @Observable state machine behind ProfileSwitcherCard's per-row
//  utilization bars. Owns one Task per profile (keyed by Profile.id),
//  exposes a `row(for:)` projection consumed by the view body, and
//  caches the last successful summary per profile so reopening the
//  popover can show useful data while a fresh fetch runs.
//
//  Cancellation: `reset()` and any subsequent `startFetching` call that
//  drops a previously-tracked profile cancel that profile's in-flight
//  Task. The dropped Task's result is discarded.
//

import Foundation

@MainActor
@Observable
final class ProfileSwitcherFetchCoordinator {
    enum RowFetch: Equatable {
        case idle
        case loading
        case loaded(ProviderUsageSummary)
        case error(String)
        /// Last-known summary shown because the most recent fetch failed
        /// transiently (rate limit / network) or returned no usable data.
        /// Rendered dimmed with an "as of <time>" tooltip.
        case stale(ProviderUsageSummary)

        static func == (lhs: RowFetch, rhs: RowFetch) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading): return true
            case let (.loaded(a), .loaded(b)):
                // Identity on providerID + fetchedAt is sufficient for the
                // view; ProviderUsageSummary holds an opaque `payload` that
                // doesn't conform to Equatable.
                return a.providerID == b.providerID && a.fetchedAt == b.fetchedAt
            case let (.stale(a), .stale(b)):
                return a.providerID == b.providerID && a.fetchedAt == b.fetchedAt
            case let (.error(a), .error(b)): return a == b
            default: return false
            }
        }
    }

    private let fetcher: any ProfileUsageFetching
    private let store: (any SwitcherSummaryStoring)?
    private let diskWriteDebounce: TimeInterval
    private let rowFreshnessWindow: TimeInterval
    private let now: () -> Date
    private var state: [UUID: RowFetch] = [:]
    private var lastSuccessful: [UUID: ProviderUsageSummary] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var pendingWrite: Task<Void, Never>?

    /// Minimum time the loading affordance must remain visible before an
    /// error triangle can replace it. Below this the user just sees a
    /// flash — the spinner appears and disappears too fast to register.
    /// Above this the wait is real and the error is informative right
    /// away. Applied as a *floor*, not an unconditional sleep: a fetch
    /// that already took longer than this incurs no additional delay.
    private static let minimumLoadingDuration: TimeInterval = 0.35

    /// Delay between the first failed attempt and the retry, for
    /// non-trust-boundary errors. 0.75 s is short enough that the
    /// spinner doesn't drag, long enough that the cold-start race
    /// (slow first OAuth refresh, CLI subprocess warming up) has
    /// usually cleared.
    private static let transientRetryDelay: UInt64 = 750_000_000

    /// User-facing message surfaced for a row whose fetch was suppressed
    /// because the active path is currently in a 429 back-off window.
    /// Cached rows keep showing their stale data; only uncached rows get
    /// this message instead of a stuck spinner.
    static let backoffSuppressedMessage = "Refresh paused — rate-limit back-off in effect"

    /// Invoked when a row fetch surfaces a 429. Receives the server's
    /// Retry-After value (nil when omitted). The host (MenuBarViewModel)
    /// pumps this into `refreshCoordinator.applyRetryAfter` so the
    /// switcher and active paths share one back-off floor — scoped to
    /// the provider whose row hit the 429, so a Claude 429 doesn't
    /// poison Antigravity / Codex floors.
    private let onRowRateLimited: (ProviderID, TimeInterval?) -> Void

    /// Consulted before each row fetch. When `true` for the row's
    /// providerID, the row is not enqueued. Per-provider so a Claude
    /// 429 doesn't suppress Antigravity / Codex rows.
    private let isExternallyBackingOff: (ProviderID) -> Bool

    init(
        fetcher: any ProfileUsageFetching,
        store: (any SwitcherSummaryStoring)? = nil,
        diskWriteDebounce: TimeInterval = 0.5,
        rowFreshnessWindow: TimeInterval = 60,
        now: @escaping () -> Date = Date.init,
        onRowRateLimited: @escaping (ProviderID, TimeInterval?) -> Void = { _, _ in },
        isExternallyBackingOff: @escaping (ProviderID) -> Bool = { _ in false }
    ) {
        self.fetcher = fetcher
        self.store = store
        self.diskWriteDebounce = diskWriteDebounce
        self.rowFreshnessWindow = rowFreshnessWindow
        self.now = now
        self.onRowRateLimited = onRowRateLimited
        self.isExternallyBackingOff = isExternallyBackingOff
        // Hydrate the in-memory cache from disk so the first row(for:)
        // call after init can already return .loaded for known profiles.
        // No fetch yet — startFetching is what kicks the refresh; this
        // only ensures the UI doesn't render an empty spinner while the
        // first fetch is in flight.
        if let store {
            self.lastSuccessful = store.load()
        }
    }

    /// Schedules a coalesced write of `lastSuccessful` to disk. Multiple
    /// calls within `diskWriteDebounce` collapse to a single write of the
    /// final state. `diskWriteDebounce == 0` writes inline (tests).
    private func scheduleDiskWrite() {
        guard let store else { return }
        pendingWrite?.cancel()
        let snapshot = lastSuccessful
        if diskWriteDebounce <= 0 {
            store.save(snapshot)
            pendingWrite = nil
            return
        }
        pendingWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.diskWriteDebounce ?? 0.5) * 1_000_000_000))
            if Task.isCancelled { return }
            self?.store?.save(snapshot)
        }
    }

    /// Test-only helper: waits for any pending debounced write to land.
    /// Inline-debounce (0s) returns immediately; non-zero waits on the
    /// scheduled Task.
    func flushPendingWriteForTests() async {
        await pendingWrite?.value
    }

    /// Test-only helper: injects a synthetic `lastSuccessful` map so
    /// tests can model "back-off active + cached row" without driving
    /// a full first-pass fetch through the mock.
    func seedLastSuccessfulForTests(_ map: [UUID: ProviderUsageSummary]) {
        lastSuccessful = map
    }

    func row(for id: UUID) -> RowFetch {
        state[id] ?? lastSuccessful[id].map(RowFetch.loaded) ?? .idle
    }

    /// Seeds the in-memory cache from the view model's per-profile last-known
    /// summaries. The active profile's summary never flows through a row
    /// fetch (`startFetching` skips the active id), so without this an
    /// inactive-but-recently-active row has no fallback and a transient fetch
    /// failure shows ⚠️ instead of stale data. Only fills an entry when it is
    /// absent or strictly older than the incoming summary, so it never
    /// downgrades a fresher fetched row. Does not touch `state`.
    ///
    /// When it mutates the cache, it schedules a disk write so a seeded
    /// (active-then-deactivated) summary survives an app restart and hydrates
    /// on the next launch — closing the cold-start gap where a profile that
    /// was active when the app quit had no persisted entry and could show ⚠️
    /// on its first inactive fetch's transient failure. A no-op seed (entry
    /// already present and not older) schedules nothing. The coordinator
    /// remains the sole writer of the store.
    func seed(_ map: [UUID: ProviderUsageSummary]) {
        var changed = false
        for (id, summary) in map {
            if let existing = lastSuccessful[id], existing.fetchedAt >= summary.fetchedAt {
                continue
            }
            lastSuccessful[id] = summary
            changed = true
        }
        if changed { scheduleDiskWrite() }
    }

    /// Starts a fetch for every profile in `profiles` whose id is not equal
    /// to `skip` and does not already have an in-flight task. Cached rows stay
    /// visually loaded while the refresh runs; uncached rows show `.loading`.
    /// Returns when every newly-started fetch has resolved.
    func startFetching(profiles: [Profile], skip: UUID?) async {
        let targets = profiles.filter { $0.id != skip }

        // Cancel and drop entries for profiles no longer in `targets`.
        // The cleanup spans all three maps — tasks, state, and
        // lastSuccessful — so an archived/removed profile doesn't leak
        // its cached summary or trigger a stale row render.
        let targetIDs = Set(targets.map(\.id))
        let staleIDs = Set(tasks.keys)
            .union(state.keys)
            .union(lastSuccessful.keys)
            .subtracting(targetIDs)
        var didEvictFromCache = false
        for id in staleIDs {
            tasks[id]?.cancel()
            tasks[id] = nil
            state[id] = nil
            if lastSuccessful[id] != nil {
                lastSuccessful[id] = nil
                didEvictFromCache = true
            }
        }
        if didEvictFromCache {
            scheduleDiskWrite()
        }

        // Collect profiles that need a new fetch and mark uncached rows
        // .loading *before* any suspension point so that one Task.yield() in
        // callers is enough to observe the loading state.
        var toFetch: [Profile] = []
        for profile in targets {
            if tasks[profile.id] != nil {
                continue
            }
            switch state[profile.id] {
            case .some(.loading), .some(.loaded):
                continue
            case .some(.idle), .some(.error), .some(.stale), nil:
                if let cached = lastSuccessful[profile.id] {
                    state[profile.id] = .loaded(cached)
                    // SWR gate: a cached row whose fetchedAt is still inside
                    // `rowFreshnessWindow` is fresh enough — don't refetch.
                    // Stops the expand→collapse→expand pattern (and the
                    // cold-start hydration pass) from draining the
                    // /api/oauth/usage token bucket on every popover open.
                    // The active path applies the same window via
                    // MenuBarViewModelSWRGate; keeping both surfaces in sync
                    // means the whole popover speaks one freshness dialect.
                    //
                    // Gated on `hasBucketData`: a degraded-but-successful
                    // summary (both bars nil — e.g. Antigravity's quota
                    // sub-fetch missed at cold start, or Codex's
                    // `rate_limit: null` 200) is not "fresh data" to protect.
                    // Treating it as fresh would freeze an empty row for the
                    // whole window, only healing on a manual profile switch
                    // (which seeds past the coordinator). An empty cached row
                    // always refetches so it self-heals on the next expand.
                    if cached.hasBucketData,
                       now().timeIntervalSince(cached.fetchedAt) < rowFreshnessWindow {
                        continue
                    }
                } else {
                    state[profile.id] = .loading
                }
                // Shared back-off: the active path is currently inside a
                // 429 retry-after window. Piling another switcher fetch
                // onto the same locked-out bucket would just earn another
                // 429 — skip the fetch. Cached rows already show their
                // stale data; uncached rows surface a clear message so
                // the spinner doesn't sit forever waiting for a fetch
                // that won't fire.
                if isExternallyBackingOff(profile.providerID) {
                    if lastSuccessful[profile.id] == nil {
                        state[profile.id] = .error(Self.backoffSuppressedMessage)
                    }
                    continue
                }
                toFetch.append(profile)
            }
        }

        // Serial loop: each row fetch is awaited before the next begins,
        // so an earlier 429's `onRowRateLimited` callback can flip the
        // shared back-off floor and the next iteration's
        // `isExternallyBackingOff` check skips before another network
        // call goes out. The previous concurrent task-group scheduling
        // launched every row's fetch before any sibling could see a
        // 429, defeating the shared-floor design. For typical switcher
        // populations (1-5 rows × ~500 ms each) the user-visible cost
        // is small; the throughput loss is the price of bucket safety.
        for profile in toFetch {
            // User collapsed mid-loop, or reset() was called — exit.
            if Task.isCancelled { break }
            // Re-check the shared back-off: an earlier row's 429 may
            // have flipped it.
            if isExternallyBackingOff(profile.providerID) {
                if lastSuccessful[profile.id] == nil {
                    state[profile.id] = .error(Self.backoffSuppressedMessage)
                }
                // Cached rows keep their .loaded(cached) state from
                // the toFetch-build loop above.
                continue
            }
            let id = profile.id
            let fetcher = self.fetcher
            // `@MainActor` on the Task body keeps all state mutations on the
            // main actor without an extra hop, so callers observing state after
            // two Task.yield()s see the final value correctly.
            let task = Task { @MainActor [weak self] in
                let startedAt = Date()
                do {
                    let summary = try await Self.fetchWithRetry(fetcher: fetcher, profile: profile)
                    try Task.checkCancellation()
                    self?.apply(.loaded(summary), for: id)
                } catch is CancellationError {
                    // Drop silently — reset() owns the post-cancel state.
                } catch {
                    // Rate-limit signal: propagate the server's
                    // Retry-After to the host so the active path's
                    // back-off floor absorbs it. Both paths now share
                    // one bucket-recovery window instead of each
                    // discovering the limit independently.
                    if case let ClaudeAPIClient.APIError.rateLimited(retryAfter) = error {
                        self?.onRowRateLimited(profile.providerID, retryAfter)
                    }
                    // Trust-boundary errors (missingCredential,
                    // missingProvider, cliIdentityMismatch) must NOT
                    // be masked by the cache: ProfileUsageFetcher
                    // raises them to fail closed against attributing
                    // a wrong account's usage to this profile, and a
                    // stale .loaded would defeat that — both visually
                    // and through switchTo's preload pathway, which
                    // would adopt the cached summary into the active
                    // VM. Evict the cache so apply() can't resurrect
                    // it. Transient errors (network, 5xx, post-retry
                    // 401) keep their cache; those rows still render
                    // last-known data while the user retries.
                    if error is ProfileUsageFetcherError {
                        if self?.lastSuccessful[id] != nil {
                            self?.lastSuccessful[id] = nil
                            self?.scheduleDiskWrite()
                        }
                    }
                    // Anti-flash floor: a fast-failing fetch (e.g.
                    // missingCredential) returns in <10 ms, so the
                    // spinner would appear and vanish before the eye
                    // catches it. Sleep up to `minimumLoadingDuration`
                    // so the user sees the loading state before the
                    // error. Slow failures (network timeouts) already
                    // exceeded the floor and get no extra delay.
                    // Reads `lastSuccessful` *after* the trust-boundary
                    // eviction above, so a fast-failing identity
                    // mismatch correctly gets the floor too.
                    let elapsed = Date().timeIntervalSince(startedAt)
                    let floor = Self.minimumLoadingDuration
                    if self?.lastSuccessful[id] == nil, elapsed < floor {
                        let remaining = floor - elapsed
                        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                        // try? — a cancellation here means reset() raced
                        // us, and reset() owns the post-cancel state; we
                        // silently exit without surfacing the error.
                        if (try? Task.checkCancellation()) == nil { return }
                    }
                    self?.apply(.error(Self.userMessage(for: error)), for: id)
                }
            }
            tasks[id] = task
            await task.value
        }
    }

    /// Cancel every in-flight task and clear transient row state. Successful
    /// summaries remain cached so the next open can render immediately from
    /// the last known data; error state is intentionally not retained.
    func reset() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        state.removeAll()
    }

    private func apply(_ row: RowFetch, for id: UUID) {
        // Only land the result if the row is still being tracked (i.e. the
        // user hasn't collapsed). A `reset()` between fetch-start and
        // completion drops the task from `tasks`; the stale completion is
        // ignored.
        guard tasks[id] != nil else { return }
        if case let .loaded(summary) = row {
            // Degraded-but-successful guard: a fetch can return HTTP 200 with
            // an empty body (Codex's `wham/usage` intermittently sends
            // `rate_limit: null`), which decodes to a valid summary whose
            // bars are both empty. Letting that overwrite a cached summary
            // that still has data would blank the row on a transient API
            // hiccup. Keep the last good summary instead; its stale
            // `fetchedAt` drives the "updated X ago" affordance honestly.
            if ProviderUsageSummary.shouldRetain(previous: lastSuccessful[id], over: summary),
               let cached = lastSuccessful[id] {
                state[id] = .stale(cached)
                AppLog.shared.log(
                    "ProfileSwitcherFetchCoordinator: dropped empty refetch for \(summary.providerID.rawValue) row — retained last good snapshot",
                    level: .info
                )
            } else {
                lastSuccessful[id] = summary
                state[id] = row
                scheduleDiskWrite()
            }
        } else if case .error = row, let cached = lastSuccessful[id] {
            state[id] = .stale(cached)
        } else {
            state[id] = row
        }
        tasks[id] = nil
    }

    /// Single-row fetch with two layered retries:
    ///
    ///   1. `ClaudeAPIClient.APIError.unauthorized` → one retry. The
    ///      providers already attempt a `forceRefresh` recovery
    ///      internally, so a 401 reaching the coordinator means the
    ///      provider's slot was consumed before we saw it; one more
    ///      try usually clears a token rotation race.
    ///   2. Any other non-trust-boundary, non-rate-limit error → one
    ///      retry after `transientRetryDelay` (0.75 s). The cold-start
    ///      row fetch occasionally hits a transient failure (slow first
    ///      OAuth refresh, CLI subprocess warming up, network blip).
    ///      Empirically the second attempt clears it.
    ///
    /// Rate-limit errors (`ClaudeAPIClient.APIError.rateLimited`) are
    /// deliberately NOT retried here. A 429 means the bucket is
    /// exhausted — retrying from the coordinator would just multiply
    /// post-429 traffic across all N-1 concurrent row fetches and
    /// likely deepen the lockout. The outer catch in `startFetching`
    /// pushes the server's Retry-After to the host (MenuBarViewModel
    /// pumps it into the shared back-off floor) and the row surfaces
    /// .error with the cached fallback if one exists.
    ///
    /// Trust-boundary errors (`ProfileUsageFetcherError`) are
    /// deterministic fail-closed signals — `missingCredential`,
    /// `missingProvider`, `cliIdentityMismatch`. Retrying them just
    /// papers over the guard. They're matched explicitly between the
    /// 401 clause and the generic catch so they propagate immediately.
    ///
    /// Both providers throw `ClaudeAPIClient.APIError.unauthorized` and
    /// `.rateLimited` as their shared error vocabulary, so catching
    /// those types covers both — there's no Claude-specific branching
    /// here.
    private static func fetchWithRetry(
        fetcher: any ProfileUsageFetching,
        profile: Profile
    ) async throws -> ProviderUsageSummary {
        do {
            return try await fetcher.fetch(profile: profile)
        } catch ClaudeAPIClient.APIError.unauthorized {
            try Task.checkCancellation()
            AppLog.shared.log(
                "ProfileSwitcherFetchCoordinator: row fetch hit 401 after provider recovery, retrying once",
                level: .warn
            )
            return try await fetcher.fetch(profile: profile)
        } catch ClaudeAPIClient.APIError.rateLimited(let retryAfter) {
            // Do not retry — surface so the outer catch can route
            // Retry-After to the shared back-off floor. Re-throwing
            // verbatim preserves the associated value for the host.
            throw ClaudeAPIClient.APIError.rateLimited(retryAfter: retryAfter)
        } catch let error as ProfileUsageFetcherError {
            // Deterministic fail-closed — don't retry, let the
            // coordinator's outer catch evict cache and surface .error.
            throw error
        } catch {
            // Generic transient — cold-start CLI race, slow first OAuth
            // refresh, server blip. One retry after a short delay.
            try Task.checkCancellation()
            try? await Task.sleep(nanoseconds: Self.transientRetryDelay)
            try Task.checkCancellation()
            AppLog.shared.log(
                "ProfileSwitcherFetchCoordinator: row fetch hit transient error, retrying once after 0.75s — \((error as NSError).localizedDescription)",
                level: .info
            )
            return try await fetcher.fetch(profile: profile)
        }
    }

    private static func userMessage(for error: Error) -> String {
        if let mapped = error as? ProfileUsageFetcherError {
            switch mapped {
            case .missingCredential:    return "Sign in to load usage"
            case .missingProvider:      return "Provider unavailable"
            case .cliIdentityMismatch:  return "Account mismatch — switch profile"
            }
        }
        // Anything else (e.g. ClaudeAPIClient.APIError, network errors) is
        // surfaced as a single friendly line; the raw description goes to
        // AppLog so it stays reachable for debugging without leaking into
        // the popover UI.
        AppLog.shared.log(
            "ProfileSwitcherFetchCoordinator: row fetch failed — \((error as NSError).localizedDescription)",
            level: .error
        )
        return "Couldn't load usage"
    }
}
