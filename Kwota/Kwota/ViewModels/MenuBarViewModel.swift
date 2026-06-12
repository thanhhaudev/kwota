//
//  MenuBarViewModel.swift
//  Kwota
//

import Foundation
import Combine
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
final class MenuBarViewModel {
    enum StartupMode {
        case live
        case hostedTests
    }

    // MARK: - Tabs

    enum Tab: String, CaseIterable, Identifiable {
        case usage, awake, cache
        var id: String { rawValue }
        var label: String {
            switch self {
            case .usage: return "Usage"
            case .awake: return "Awake"
            case .cache: return "Cache"
            }
        }
        var icon: String {
            switch self {
            case .usage: return "chart.bar.fill"
            case .awake: return "cup.and.saucer.fill"
            case .cache: return "internaldrive.fill"
            }
        }
    }

    var selectedTab: Tab = .usage

    // MARK: - Usage tab — OAuth-API-derived state (currently stubbed)

    var authState: AuthState = .refreshing
    private(set) var snapshot: UsageSnapshot?
    /// Default `internal` (rather than `private(set)`) so the
    /// stale-data regression tests in `MenuBarViewModelRefreshGateTests`
    /// can seed a "before" value and assert `rebindHistory` clears it.
    /// Production write sites are confined to `refresh(profile:)`.
    var summary: ProviderUsageSummary?
    /// Last-known summary per profile id, updated on every successful active
    /// commit. `ProfileSwitcherCard` seeds these into the switcher coordinator
    /// so a just-deactivated profile has a stale fallback instead of ⚠️ when
    /// its first inactive-row fetch fails transiently.
    private(set) var lastSummaryByProfile: [UUID: ProviderUsageSummary] = [:]
    /// Per-profile notification evaluator. Holds in-memory dedup state.
    let notificationDispatcher = NotificationDispatcher()
    let notificationSettingsStore = NotificationSettingsStore()
    private(set) var history: [UsageHistoryEntry] = []
    private(set) var lastFetchedAt: Date?
    private(set) var lastError: String?
    private(set) var isSwitchingProfile: Bool = false

    // MARK: - Usage tab chart-region resolution

    /// Resolution of the Usage tab's chart region. Pure projection of
    /// `summary`, `snapshot`, and `isSwitchingProfile`; views bind via
    /// `usageChartState(for:)`.
    enum UsageChartState {
        case loading
        case providerView(ProviderUsageSummary)
        case empty
    }

    /// Pure static resolver. Kept separate from the instance method so tests
    /// don't need to construct a VM (the VM's `snapshot` / `isSwitchingProfile`
    /// are `private(set)` and not writable via @testable).
    ///
    /// Order of preference:
    /// 1. Live `summary` if present (any provider).
    /// 2. Claude-only: a cached `snapshot` adapted into a `ProviderUsageSummary`
    ///    so the offline-first UX survives — Codex doesn't write `snapshot`,
    ///    so its cached path never engages.
    /// 3. `.loading` when mid-switch with no data.
    /// 4. `.empty` otherwise — drives the "No data yet — tap Refresh" placeholder.
    ///
    /// This is the fix for the Codex-active + no-summary case: the previous
    /// UsageTabView fallback substituted `UsageSnapshot.zeroes()` (a Claude
    /// payload) into a freshly-built `ProviderUsageSummary`. CodexProvider then
    /// rejected the cast and returned `EmptyView()`, leaving the popover blank.
    static func resolveUsageChartState(
        for profile: Profile,
        summary: ProviderUsageSummary?,
        snapshot: UsageSnapshot?,
        isSwitchingProfile: Bool
    ) -> UsageChartState {
        // Provider-id guard: a `summary` left over from the previous active
        // profile must NOT be handed to a different provider's detail view.
        // Without this check, a missed/late rebind window could render a
        // Codex chart with Claude payload (or vice versa). ProviderUsageSummary
        // carries no profile id, so providerID equality is the minimum guard.
        if let summary, summary.providerID == profile.providerID {
            return .providerView(summary)
        }
        if profile.providerID == .claude, let cached = snapshot {
            let adapted = ProviderUsageSummary(
                providerID: .claude,
                fetchedAt: cached.fetchedAt,
                primary: nil,
                secondary: nil,
                payload: cached
            )
            return .providerView(adapted)
        }
        if isSwitchingProfile { return .loading }
        return .empty
    }

    /// View-facing shorthand: forwards `self`'s state into the static resolver.
    func usageChartState(for profile: Profile) -> UsageChartState {
        Self.resolveUsageChartState(
            for: profile,
            summary: summary,
            snapshot: snapshot,
            isSwitchingProfile: isSwitchingProfile
        )
    }

    /// Set when Anthropic returns 429 on the active path. Cleared on the
    /// next successful refresh. Drives the rate-limit banner in the Usage
    /// tab so the user understands why a manual Refresh appeared to do
    /// nothing — the snapshot stays as-is by design while we honor the
    /// server-driven back-off.
    private(set) var rateLimitedUntil: Date?

    /// Number of consecutive 429s where the server did NOT supply a usable
    /// Retry-After. Drives the exponential fallback schedule (60s, 120s,
    /// 240s, 300s cap) so the first 429 doesn't lock us out for a full
    /// 5 minutes when the throttle is transient. Reset on any successful
    /// snapshot commit. 429s that come with an explicit Retry-After do
    /// not advance this counter — the server is being explicit and its
    /// value is honored as-is.
    private var consecutive429Count: Int = 0

    /// True when the user has not added any profile yet. Drives the
    /// empty-state UI in `UsageTabView`.
    var hasNoProfiles: Bool { profileStore.profiles.isEmpty }

    /// True when no profile is currently active — either because no profiles
    /// exist or all are archived. The popover empty state gates on this so
    /// signed-out users still see the right hint even when archived history
    /// remains in the store.
    var hasNoActiveProfile: Bool { profileStore.activeProfileId == nil }

    /// Single source of truth for the "Refreshing…" loader.
    /// Must release in the no-profile state — otherwise the loader buries
    /// the Add-Profile entry point forever (regression from the bundle-id
    /// rename that left existing users with zero migrated profiles).
    ///
    /// `snapshot` is the Claude-only cached `UsageSnapshot`. Non-Claude
    /// providers (Codex) never populate it, so we also consult `summary` —
    /// the provider-agnostic last successful fetch — before showing the
    /// loader. Without this, every popover reopen with a Codex profile
    /// blanks the chart to "Refreshing…" until the next fetch lands.
    var showLoadingPlaceholder: Bool {
        if hasNoProfiles { return false }
        if isSwitchingProfile { return true }
        if snapshot == nil && summary == nil { return authState == .refreshing }
        return false
    }

    // MARK: - Profiles

    let profileStore: ProfileStore
    let registry: ProviderRegistry
    let credentialStore: KeychainCredentialStore
    /// Lazy fetcher used by ProfileSwitcherCard to populate per-row
    /// utilization bars on expand. Default-live; tests pass a mock that
    /// satisfies `ProfileUsageFetching` directly so coordinator unit tests
    /// can run independently of this VM.
    let profileUsageFetcher: any ProfileUsageFetching
    /// Live `/api/oauth/profile` client. Shared with `AutoProfileCoordinator`;
    /// the same instance is passed to both via init. Used by
    /// `refreshProfileMetadata(for:)` to honor the user's Refresh button on
    /// the profile detail sheet.
    let oauthProfileFetcher: any OAuthProfileFetching
    private let apiClient: ClaudeAPIClient
    private let cliRefresher: CLITokenRefresher
    /// Spawns `claude -p` for Cache → AI evaluation. CLI route is the
    /// only auth path that actually works for `/v1/messages`-style
    /// generation today (third-party OAuth Bearer is gated).
    private let cliRunner: ClaudeCLIInvocation
    let privilegedHelper: PrivilegedHelperManager
    private var historyStore: UsageHistoryStore?
    /// Maps a profile id to its usage-history file. Defaults to the live
    /// `AppPaths.usageHistoryFile(id:)`; tests inject a temp-dir mapping so
    /// 200-path refreshes never write under the real per-profile dirs.
    private let historyFileProvider: (UUID) -> URL
    var refreshCoordinator: UsageRefreshCoordinator?
    /// Disk-backed Cache-tab state (settings, AI evals, custom paths,
    /// toggles, risky-alert acks). Read once on init to seed `cacheState`,
    /// written synchronously after every mutation that touches a
    /// persisted field.
    private let cachePersistence: CachePersistenceStore
    private var cancellables: Set<AnyCancellable> = []
    // `nonisolated(unsafe)` so `deinit` (which runs nonisolated under
    // strict Swift concurrency) can read these observers to call
    // `removeObserver`. They're only ever mutated on the main actor in
    // `init`, then read once on deinit — single-writer, single-reader, safe.
    private nonisolated(unsafe) var sleepObserver: NSObjectProtocol?
    private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?
    /// Observer on `UserDefaults.didChangeNotification` so the live
    /// `refreshCoordinator` picks up Battery Saver toggles without
    /// requiring an app relaunch. Same single-writer/single-reader
    /// pattern as `sleepObserver`.
    private nonisolated(unsafe) var pollingModeObserver: NSObjectProtocol?
    private var lastKnownPollingMode: PollingMode = .normal
    /// Long-running Task that drives the background cache scan + auto-clean
    /// loop. Written once during `init` (when `.live`) and may be replaced
    /// when the user changes `scanInterval` from Settings — at which point
    /// the previous Task is cancelled and a fresh one starts so the new
    /// interval takes effect immediately rather than after the in-flight
    /// sleep finishes. Read on `deinit` to cancel — same single-writer/
    /// single-reader pattern as `sleepObserver`.
    private nonisolated(unsafe) var cacheSchedulerTask: Task<Void, Never>?

    /// Bumped on every profile switch. A refresh Task captures this on
    /// entry; only commits to UI state if the value is still current at
    /// completion. Prevents an older in-flight Task from clobbering a
    /// newer switch's data — even when both are for the same profile.
    private var refreshGeneration: Int = 0

    /// Test seam for time-dependent gating (throttle floor, back-off
    /// expiration). Production callers omit this; tests inject a mutable
    /// clock so they can advance time without `Task.sleep`.
    let now: () -> Date

    /// Minimum gap between consecutive refresh *attempts*, regardless of
    /// trigger source. Suppresses burst-y refreshes from popover open +
    /// simultaneous coordinator tick, from rapid manual button taps, and
    /// from tab switching (after the lifecycle fix). Server-side back-off
    /// stacks on top of this; this floor is self-defense, the coordinator's
    /// `backoffUntil` honors the server's hint.
    let refreshThrottle: TimeInterval = 10

    /// SWR window for the opportunistic refresh path. When `popoverDidOpen`
    /// fires and `summary.fetchedAt` is within this many seconds of `now()`,
    /// the refresh call is skipped — the cached summary is fresh enough and
    /// the periodic 60s tick will issue the next call. Set to the observed
    /// `/api/oauth/usage` cadence (60s open-interval).
    let freshnessWindow: TimeInterval = 60

    /// Timestamp of the most recent refresh *attempt* — set on entry to
    /// `refreshUsageNow`, not on successful commit. So a failed fetch still
    /// counts toward the throttle floor (we don't want to retry network
    /// failures faster than the floor). Reset to `nil` on profile switch
    /// and `replaceCredentials` so a new credential fetches immediately.
    var lastFetchAttemptAt: Date?

    // Subscription card fields are derived from the active profile.

    /// Sourced from `oauthAccount.emailAddress` if a CLI profile is active.
    /// Nil otherwise (sessionKey paste path doesn't carry an email yet).
    var subscriptionEmail: String? {
        profileStore.activeProfile?.email
    }

    /// Derived from the active profile's `subscriptionPlan`. Values are
    /// pre-formatted by `PlanFormatter` ("Max", "Max 20x", "Team Premium",
    /// etc.) so we return them verbatim. We deliberately do NOT apply
    /// `String.capitalized` here: Foundation's ICU word-break splits digits
    /// from letters, so `"Max 20x".capitalized` returns `"Max 20X"` and the
    /// tier suffix renders wrong in the badge.
    var subscriptionPlan: String? {
        profileStore.activeProfile?.subscriptionPlan
    }

    /// Next renewal date: assume monthly cycle anchored on
    /// `subscriptionCreatedAt`. Steps the anchor forward by 1-month
    /// increments past `now`. Prefer an explicit
    /// `profile.subscriptionRenewsAt` when present (Codex JWT-sourced).
    ///
    /// Pure static so both the active-profile header card and the
    /// inactive switcher rows can share one source of truth without the
    /// row builder needing a VM instance.
    ///
    /// Risk 2 caveat: monthly assumption. Annual plans (Team yearly,
    /// Enterprise) will show the wrong extrapolated date — we'd need an
    /// explicit billing-cycle field from Anthropic to fix, and the
    /// bootstrap response doesn't expose one today. The UI hedges this
    /// by prefixing "Est." in `subscriptionRenewalText`.
    ///
    /// Defensive cap at 600 iterations (~50 years of monthly cycles)
    /// guards against an infinite loop if Calendar.date(byAdding:) ever
    /// returns nil or the same date — we'd rather render no renewal than
    /// hang the UI thread.
    static func estimatedRenewal(for profile: Profile, now: Date) -> Date? {
        RenewalEstimator.subscription(for: profile, now: now)
    }

    /// Abbreviated absolute date, e.g. "6 Jun 2026". Matches the `abs`
    /// portion in `subscriptionRenewalText`; shared with the switcher
    /// row builder so the two surfaces never drift apart.
    static func formattedRenewalDate(_ date: Date) -> String {
        RenewalEstimator.formattedDate(date)
    }

    /// Active-profile renewal date — delegates to the static helper.
    var subscriptionRenewsAt: Date? {
        guard let active = profileStore.activeProfile else { return nil }
        return Self.estimatedRenewal(for: active, now: Date())
    }

    /// Renewal/reset text for the active profile, driven by the active
    /// provider's `renewalEstimate` hook. Absolute estimates include a
    /// relative hint ("Est. 18 Jun 2026 · in 20 days"); relative-only
    /// estimates show just the phrase ("Resets in 2h").
    var subscriptionRenewalText: String? {
        guard let active = profileStore.activeProfile,
              let provider = registry.provider(for: active.providerID),
              let est = provider.renewalEstimate(profile: active, summary: summary, now: Date())
        else { return nil }
        return RenewalEstimator.headerString(est, now: Date())
    }

    /// Tooltip body for the renewal estimate. Surfaced via `.help()` on
    /// an info icon next to the renewal text. Centralizes the wording so
    /// view code stays presentation-only.
    var subscriptionRenewalTooltip: String {
        switch profileStore.activeProfile?.providerID {
        case .codex:
            return "Current ChatGPT billing period end, read from the Codex CLI's id_token. May shift slightly if you upgrade or cancel mid-cycle."
        case .antigravity:
            return "Estimated from an observed credit reset, projected monthly. Before Kwota has seen a reset it shows the soonest model rate-limit reset instead."
        default:
            return "Approximation based on plan creation date assuming a monthly cycle. Annual plans or mid-cycle upgrades may differ."
        }
    }

    /// Whether the active profile is on a Free plan (chart overlays gate on
    /// this). Two-signal gate that resists the common failure mode where
    /// `subscriptionPlan` is nil for sessionKey-pasted profiles (the web flow
    /// has no plan-probe endpoint wired yet, and `replaceCredentials`
    /// preserves whatever the matched CLI profile had — often nil too).
    ///
    /// - **planSaysFree**: only true when the field is *explicitly* "Free".
    ///   nil counts as unknown, not Free — that was the source of the bug
    ///   where paid sessionKey users saw their charts locked behind the
    ///   "Not available on Free plan" overlay.
    /// - **dataProvesPaid**: any per-model bucket or ExtraUsage being
    ///   active is hard evidence of a paid tier — Free accounts don't get
    ///   per-model breakdowns or extra-credit billing. The seven_day total
    ///   alone isn't a reliable signal because the Messages API path
    ///   defaults it to 0% even for Free.
    /// - The combined rule `planSaysFree && !dataProvesPaid` keeps the
    ///   overlay live for actual Free users (or accounts Anthropic stamps
    ///   "Free" with no other data) and removes it the moment the snapshot
    ///   contradicts the label.
    var isFreePlan: Bool {
        Self.computeIsFreePlan(plan: subscriptionPlan, snapshot: snapshot)
    }

    nonisolated static func computeIsFreePlan(plan: String?, snapshot: UsageSnapshot?) -> Bool {
        let planSaysFree = plan?.caseInsensitiveCompare("Free") == .orderedSame
        guard let snapshot else { return planSaysFree }
        
        // If it's the "zeroes" placeholder (fetchedAt is .distantPast), we haven't 
        // actually fetched data yet. In this state, we should still show the 
        // overlay if the plan is Free, to avoid showing empty charts.
        guard snapshot.fetchedAt != .distantPast else { return planSaysFree }

        // Overlay is hidden if we have ANY displayable data, even if plan says Free.
        let hasDisplayableData = snapshot.fiveHour.utilization != nil
            || snapshot.sevenDay.utilization != nil
            || snapshot.effectiveSevenDayOpus()?.utilization != nil
            || snapshot.effectiveSevenDaySonnet()?.utilization != nil
            || snapshot.effectiveSevenDayOmelette()?.utilization != nil
            || (snapshot.extra?.isEnabled == true)
            
        return planSaysFree && !hasDisplayableData
    }

    // Usage tab — jsonl fallback (existing v1 source)
    private(set) var sessionTokens: Int = 0
    private(set) var dailyTokens: Int = 0

    // MARK: - Awake

    let awake: AwakeSupervisor

    /// Convenience for menu-bar icon overlay color: true while any keep-awake
    /// is active (auto or manual). batteryBlocked counts as not-active here.
    var awakeIsActive: Bool {
        switch awake.state {
        case .autoActive, .manualActive: return true
        case .idle, .batteryBlocked:     return false
        }
    }

    // MARK: - Awake dashboard data

    let awakeSessionLog: AwakeSessionLog
    let activityHistorian: ActivityHistorian
    private(set) var lastUsageTick: Date?
    private(set) var isNotificationPermissionDenied: Bool = false

    // MARK: - Awake tab — Agent Processes section

    private let agentProcessScanner: AgentProcessScanner
    private let agentProcessKiller: any AgentProcessKilling
    /// Snapshot rendered by AgentProcessesCard. Orphans sort first.
    private(set) var agentProcesses: [AgentProcessInfo] = []
    /// Inline-alert text for a failed kill; nil hides the alert.
    private(set) var agentProcessKillNotice: String?
    private var agentProcessPollTask: Task<Void, Never>?
    /// Bumped by stopAgentProcessPolling; an in-flight scan that started
    /// under an older generation discards its result instead of clobbering
    /// newer state (stop/start tab flap).
    private var agentProcessScanGeneration = 0
    var isAgentProcessPollingActive: Bool { agentProcessPollTask != nil }
    /// 5 s while the Awake tab is visible. Internal so tests can shrink it.
    var agentProcessPollIntervalNanos: UInt64 = 5_000_000_000
    /// Post-SIGTERM rescan delay. Tests set 0.
    var agentProcessRescanDelayNanos: UInt64 = 500_000_000

    // MARK: - Cache tab state

    /// State for the Cache tab.
    struct CacheState: Equatable {
        var rows: [CachePathRow]
        var settings: AutoCleanSettings
        var nextScanAt: Date?
        var lastCleanedAt: Date?
        var lastCleanedBytes: Int?
        /// Real disk scan in flight (CacheCleaner). View reads this to swap
        /// the folder list for a loading state. Distinct from the top-level
        /// `isScanning` (which tracks the Claude usage refresh).
        var isScanning: Bool = false
        /// Real trash-move in flight (CacheCleaner.clean). Set independently
        /// from `isScanning` so the popover can show "Cleaning…" without
        /// the loading-state placeholder taking over.
        var isCleaning: Bool = false
        /// Timestamp of the most recently completed scan. nil until the
        /// first scan finishes; gates the interval-based refresh check.
        var lastScannedAt: Date?
        /// Currently running bulk-evaluate animation. Footer AI button reads
        /// this to swap into a spinner; per-row "Re-evaluate" reads
        /// `evaluatingRowIDs` instead.
        var isEvaluatingAll: Bool = false
        /// Row IDs whose per-row Re-evaluate action is mid-flight.
        var evaluatingRowIDs: Set<UUID> = []
        /// Row IDs whose per-row Clean action is mid-flight. The row view
        /// reads this to dim itself and float a "Removing…" overlay until
        /// the trash-move + rescan finish.
        var cleaningRowIDs: Set<UUID> = []
        /// Most-recent AI evaluation failure, surfaced inline under the
        /// folder list. Cleared when the user starts a new evaluation or
        /// dismisses the banner — runtime-only, not persisted.
        var aiEvaluationError: CacheEvaluator.EvaluationError?
        /// Last privileged-helper failure from a *manual* system-cache clean.
        /// Drives an inline alert on the Cache tab. Background auto-clean
        /// failures are logged only and never set this.
        var systemCleanError: PrivilegedHelperError?
        /// Last user-initiated normal-cache clean failure. Drives an inline
        /// alert on the Cache tab similar to `systemCleanError` but for the
        /// non-privileged-helper path. Background auto-clean
        /// (`surfaceErrors == false`) is logged only and never sets this.
        var normalCleanError: String?
        /// User-selected model. Phase 2 will forward this to the API client.
        var aiModel: AIModelChoice = .default
        /// Paths the user has already been alerted about as "risky". Lives
        /// in-memory for now — Phase 5 persists it so the alert truly fires
        /// once per path across launches. Cleared by `cacheClearAIEvaluations`.
        var riskyAlertedPaths: Set<URL> = []
        /// Items Kwota itself moved to ~/.Trash. Mirrors
        /// `CachePersistedState.trashedItems` — populated when `cacheClean`
        /// succeeds, swept by `purgeOldTrashedItemsIfEnabled` at scheduler
        /// tick start when the user has opted into the time-bounded purge.
        var trashedItems: [CachePersistedState.TrashedItem] = []
        /// `URL.path` strings of built-in rows the user removed from tracking.
        /// Mirrors `CachePersistedState.removedDefaultPaths`; the hydration
        /// re-seed and the Add-menu restore section both read it.
        var removedDefaultPaths: Set<String> = []
    }

    var cacheState: CacheState = CacheState(
        rows: CacheStubData.defaultRows(),
        settings: .stubDefault,
        nextScanAt: nil,
        lastCleanedAt: Date().addingTimeInterval(-2 * 60 * 60),
        lastCleanedBytes: Int(12.3 * 1_000_000_000)
    )

    // MARK: - v1 backward-compat shims (legacy MenuBarView/DebugPanelView still reference these)

    private(set) var recentEvents: [UsageEvent] = []
    private(set) var lastCacheReport: CacheReport?
    private(set) var lastProbe: ProbeResult?
    var remainingDisplay: String {
        let pct: Double? = snapshot?.fiveHour.utilization ?? summary?.primary?.utilization
        if let u = pct { return "\(Int(u))%" }
        return "~?"
    }

    // MARK: - Services

    let usage: UsageMonitor
    let caffeine: CaffeinateManager
    let probe: ClaudeProbe
    let cache: CacheCleaner
    let shortcutCoordinator: ShortcutCoordinator
    let cliAccountWatcher: CLIAccountWatcher
    let codexAccountWatcher: CodexAccountWatcher
    let antigravityProcessWatcher: AntigravityProcessWatcher
    let autoProfileCoordinator: AutoProfileCoordinator
    let codexAutoProfileCoordinator: CodexAutoProfileCoordinator
    let antigravityAutoProfileCoordinator: AntigravityAutoProfileCoordinator
    private let autoProfileMigrator: AutoProfileMigrator

    // MARK: - Init

    init(
        usage: UsageMonitor? = nil,
        caffeine: CaffeinateManager? = nil,
        probe: ClaudeProbe? = nil,
        cache: CacheCleaner? = nil,
        cachePersistence: CachePersistenceStore? = nil,
        profileStore: ProfileStore? = nil,
        credentialStore: KeychainCredentialStore? = nil,
        profileUsageFetcher: (any ProfileUsageFetching)? = nil,
        apiClient: ClaudeAPIClient? = nil,
        cliRefresher: CLITokenRefresher? = nil,
        cliRunner: ClaudeCLIInvocation? = nil,
        privilegedHelper: PrivilegedHelperManager? = nil,
        registry: ProviderRegistry? = nil,
        shortcutCoordinator: ShortcutCoordinator? = nil,
        awake: AwakeSupervisor? = nil,
        activitySource: ActivitySource? = nil,
        battery: BatteryMonitoring? = nil,
        awakeNotifier: AwakeNotifying? = nil,
        awakeConfigStore: AwakeConfigStore? = nil,
        awakeSessionLog: AwakeSessionLog? = nil,
        cliAccountWatcher: CLIAccountWatcher? = nil,
        codexAccountWatcher: CodexAccountWatcher? = nil,
        antigravityProcessWatcher: AntigravityProcessWatcher? = nil,
        oauthProfileFetcher: (any OAuthProfileFetching)? = nil,
        autoProfileCoordinator: AutoProfileCoordinator? = nil,
        codexAutoProfileCoordinator: CodexAutoProfileCoordinator? = nil,
        antigravityAutoProfileCoordinator: AntigravityAutoProfileCoordinator? = nil,
        autoProfileMigrator: AutoProfileMigrator? = nil,
        activityHistorian: ActivityHistorian? = nil,
        agentProcessScanner: AgentProcessScanner? = nil,
        agentProcessKiller: (any AgentProcessKilling)? = nil,
        historyFileProvider: ((UUID) -> URL)? = nil,
        now: @escaping () -> Date = Date.init,
        startupMode: StartupMode = .live
    ) {
        self.now = now
        self.usage    = usage    ?? UsageMonitor.live()
        self.caffeine = caffeine ?? CaffeinateManager()
        self.probe    = probe    ?? ClaudeProbe()
        self.cache    = cache    ?? CacheCleaner()
        self.shortcutCoordinator = shortcutCoordinator ?? ShortcutCoordinator()
        self.profileStore = profileStore ?? ProfileStore.live()
        let resolvedCredentialStore = credentialStore ?? KeychainCredentialStore.live()
        self.credentialStore = resolvedCredentialStore
        let resolvedAPIClient = apiClient ?? ClaudeAPIClient.live()
        self.apiClient = resolvedAPIClient
        let resolvedCLIRefresher = cliRefresher ?? CLITokenRefresher(store: resolvedCredentialStore)
        self.cliRefresher = resolvedCLIRefresher
        self.cliRunner = cliRunner ?? ClaudeCLIRunner()
        self.privilegedHelper = privilegedHelper ?? PrivilegedHelperManager.live()

        // Both defaults are inert at init time (no IO until scan()/kill is
        // called), so test fixtures that don't care about this feature can
        // skip injecting them without hanging the test host.
        self.agentProcessScanner = agentProcessScanner ?? AgentProcessScanner()
        self.agentProcessKiller = agentProcessKiller ?? SystemAgentProcessKiller()

        // Hosted-tests use a tmp file so suite runs don't stomp on the
        // user's real persisted cache state. Live mode points at the
        // standard Application Support file. Tests that exercise cache
        // persistence inject their own store to stay hermetic.
        self.cachePersistence = cachePersistence ?? (startupMode == .live
            ? CachePersistenceStore()
            : CachePersistenceStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("kwota-test-cache-state-\(UUID().uuidString).json")))
        self.historyFileProvider = historyFileProvider ?? { AppPaths.usageHistoryFile(id: $0) }

        // Default registry comes pre-loaded with a ClaudeProvider that wraps
        // the same service instances the VM holds. Tests override by passing
        // a registry pre-populated with stub providers.
        let resolvedProfileStore = profileStore ?? ProfileStore.live()
        // Antigravity watcher is constructed before the registry block because
        // AntigravityProvider needs the watcher at registration time (unlike
        // Codex/Claude which look up identity lazily via separate watchers
        // assigned after the registry is built).
        let antigravityWatcherInternal = antigravityProcessWatcher ?? AntigravityProcessWatcher()
        // Resolved here (above the registry block) so the same fetcher instance
        // backs both the registered ClaudeProvider's metadata-refresh path and
        // the auto-profile coordinator below — tests inject one stub and it
        // reaches both.
        let resolvedFetcher = oauthProfileFetcher ?? OAuthProfileFetcher()
        if let registry {
            self.registry = registry
        } else {
            let r = ProviderRegistry()
            r.register(ClaudeProvider(
                apiClient: resolvedAPIClient,
                cliReader: CLICredentialReader(),
                cliRefresher: resolvedCLIRefresher,
                accountReader: OAuthAccountReader(),
                profileFetcher: resolvedFetcher,
                profileStore: self.profileStore
            ))
            let codexReader = CodexAuthReader()
            r.register(CodexProvider(
                apiClient: CodexAPIClient.live(),
                authReader: codexReader,
                tokenRefresher: CodexTokenRefresher(
                    reader: codexReader,
                    store: resolvedCredentialStore
                ),
                profileStore: self.profileStore
            ))
            let antigravityAPIClient = AntigravityAPIClient.live()
            r.register(AntigravityProvider(
                apiClient: antigravityAPIClient,
                watcher: antigravityWatcherInternal,
                profileStore: self.profileStore
            ))
            self.registry = r
        }

        let resolvedWatcher = cliAccountWatcher ?? CLIAccountWatcher()
        self.cliAccountWatcher = resolvedWatcher
        let resolvedCodexWatcher = codexAccountWatcher ?? CodexAccountWatcher()
        self.codexAccountWatcher = resolvedCodexWatcher
        self.antigravityProcessWatcher = antigravityWatcherInternal

        self.profileUsageFetcher = profileUsageFetcher ?? LiveProfileUsageFetcher(
            registry: self.registry,
            credentialStore: self.credentialStore,
            liveIdentityProvider: { [weak resolvedWatcher, weak resolvedCodexWatcher] in
                [
                    .claude: resolvedWatcher?.current?.email,
                    .codex:  resolvedCodexWatcher?.current?.email,
                    // Antigravity identity carries no email; the provider
                    // attributes by profile UUID instead.
                    .antigravity: nil
                ]
            }
        )
        self.oauthProfileFetcher = resolvedFetcher
        self.autoProfileCoordinator = autoProfileCoordinator ?? AutoProfileCoordinator(
            watcher: resolvedWatcher,
            profileStore: self.profileStore,
            keychain: self.credentialStore,
            credentialReader: CLICredentialReader(),
            profileFetcher: resolvedFetcher
        )
        self.codexAutoProfileCoordinator = codexAutoProfileCoordinator ?? CodexAutoProfileCoordinator(
            watcher: resolvedCodexWatcher,
            profileStore: self.profileStore,
            keychain: self.credentialStore,
            clock: { Date() }
        )
        self.antigravityAutoProfileCoordinator = antigravityAutoProfileCoordinator ?? AntigravityAutoProfileCoordinator(
            watcher: antigravityWatcherInternal,
            profileStore: self.profileStore,
            keychain: self.credentialStore,
            clock: { Date() }
        )
        self.autoProfileMigrator = autoProfileMigrator ?? AutoProfileMigrator(
            profileStore: self.profileStore
        )

        let resolvedAwakeStore = awakeConfigStore ?? AwakeConfigStore()
        let resolvedBattery = battery ?? IOPowerSourcesBatteryMonitor()
        let resolvedNotifier = awakeNotifier ?? UNAwakeNotifier()

        // Persistence is gated on live startup so tests don't read/write
        // the real ~/Library/Application Support file — matches the same
        // pattern used for activityHistorian's backfill scan. Constructed
        // before the supervisor so its sleep/wake callbacks can capture it.
        let resolvedSessionLog = awakeSessionLog ?? AwakeSessionLog(
            persistURL: startupMode == .live ? AwakeSessionLog.defaultPersistURL() : nil,
            caffeine: self.caffeine
        )
        self.awakeSessionLog = resolvedSessionLog

        let resolvedActivitySource: ActivitySource?
        if let awake {
            self.awake = awake
            resolvedActivitySource = nil
        } else {
            let composite = activitySource ?? CompositeActivitySource(sources: [
                UsageMonitorActivitySource(usage: self.usage),
                CodexActivitySource(
                    isLive: { [weak resolvedCodexWatcher] in
                        resolvedCodexWatcher?.current != nil
                    },
                    isClaudeCodexCompanionRunning: { CodexActivitySource.defaultCompanionRunning() }
                ),
                AntigravityActivitySource(isLive: { [weak antigravityWatcherInternal] in
                    antigravityWatcherInternal?.currentPID != nil
                }),
            ])
            self.awake = AwakeSupervisor(
                caffeine: self.caffeine,
                activity: composite,
                battery: resolvedBattery,
                notifier: resolvedNotifier,
                configStore: resolvedAwakeStore,
                onWillSleep: { [weak resolvedSessionLog] date, _ in
                    resolvedSessionLog?.closeOpenSessions(at: date)
                },
                onDidWakeFromSleep: { [weak resolvedSessionLog] date, state in
                    switch state {
                    case .autoActive:
                        resolvedSessionLog?.openSession(mode: .auto, at: date)
                    case .manualActive:
                        resolvedSessionLog?.openSession(mode: .manual, at: date)
                    case .idle, .batteryBlocked:
                        break
                    }
                }
            )
            if startupMode == .live { composite.start() }
            resolvedActivitySource = composite
        }
        // Backfill scan is gated on live startup so unit tests with a stub
        // historian don't touch the real `~/.claude/projects` tree.
        // persistURL same gating — tests don't touch real Application Support.
        let builtHistorian = (activityHistorian == nil)
        self.activityHistorian = activityHistorian
            ?? ActivityHistorian(
                autoBackfill: startupMode == .live,
                // Defer launch-time `~/.claude/projects` backfill so the first
                // provider refresh's URLRequest bridge completes before the
                // scan's heavy CF/JSON traffic ramps up — workaround for a
                // null-isa crash observed in `URLRequest._bridgeToObjectiveC`
                // on some hosts under sustained concurrent CF allocation.
                autoBackfillDelay: startupMode == .live ? 5 : 0,
                persistURL: startupMode == .live ? ActivityHistorian.defaultPersistURL() : nil
            )

        // Forward non-Claude activity into the historian so the chart can draw a
        // per-provider wave. Claude already flows through the uuid-deduped
        // UsageMonitor path (`usage.onNewEvents` below); forwarding it here would
        // double-count it and use a coarser signal, so it's filtered out.
        // Only `.agentResponse` events are recorded here — `.fileWrite` pulses
        // drive keep-awake via AwakeSupervisor's own subscription to the composite.
        if let resolvedActivitySource {
            resolvedActivitySource.activityPublisher
                .sink { [weak self] event in
                    guard event.provider != .claude else { return }
                    // Only agent replies feed the chart (Claude's unit). The
                    // raw `.fileWrite` pulse is for keep-awake (AwakeSupervisor
                    // subscribes to the composite separately).
                    guard event.kind == .agentResponse else { return }
                    let delta = Date().timeIntervalSince(event.date)
                    AppLog.shared.log(
                        "ACTIVITY_TRACE sink provider=\(event.provider.rawValue) date=\(event.date) deltaFromNow=\(String(format: "%.1f", delta))s",
                        level: .info)
                    self?.activityHistorian.record(provider: event.provider, at: event.date)
                }
                .store(in: &cancellables)
        }

        // Bind real services. `@Observable` doesn't expose `$prop` projections,
        // so we sink Combine emissions explicitly. UsageMonitor / CaffeinateManager
        // remain `ObservableObject` upstream — that's fine; we just consume their
        // `@Published` outputs here.
        self.usage.$sessionTokens
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.sessionTokens = $0 }
            .store(in: &cancellables)
        self.usage.$dailyTokens
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.dailyTokens = $0 }
            .store(in: &cancellables)
        self.usage.$lastEvents
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.recentEvents = $0 }
            .store(in: &cancellables)

        self.usage.$lastTickAt
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastUsageTick = $0 }
            .store(in: &cancellables)

        // Pipe newly-ingested assistant events into the historian so the
        // activity chart's wave updates live. `UsageMonitor` already dedup's
        // via `UsageLedger`, but historian re-dedup's on `uuid` because
        // backfill may have already seeded the same event from disk.
        self.usage.onNewEvents = { [weak self] events in
            Task { @MainActor in
                self?.activityHistorian.record(events)
            }
        }

        resolvedNotifier.isPermissionDeniedPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.isNotificationPermissionDenied = $0 }
            .store(in: &cancellables)

        // No profile yet → empty state. rebindHistory replaces this when an
        // active profile is bound, with cached snapshot or nil while a fetch
        // is in flight.
        self.snapshot       = nil
        self.lastFetchedAt  = nil

        // Bind history to the active profile's UsageHistoryStore.
        // ProfileStore is now @Observable — wire via callback instead of
        // Combine projection. The didSet on activeProfileId guards against
        // duplicate fires (matching the prior `.removeDuplicates()`).
        self.profileStore.onActiveProfileChange = { [weak self] id in
            self?.rebindHistory(for: id)
            self?.rebindUsageMonitorOwnership()
        }
        // Apply persisted Cache state BEFORE starting the scheduler so the
        // scheduler picks up the user's chosen `scanInterval` on first run
        // rather than the stub default.
        self.applyPersistedCacheState(self.cachePersistence.load())

        if startupMode == .live {
            // Same blast radius as the Claude backfill above: only when we built
            // the historian ourselves (injected historians opt out).
            if builtHistorian {
                let scanners = [
                    ProviderActivityBackfill.codex(),
                    ProviderActivityBackfill.antigravity(),
                ]
                Task { [weak self] in
                    await self?.activityHistorian.backfillProvidersAsync(scanners)
                }
            }
            // Migrator runs FIRST so an in-place promotion (legacy active
            // profile gets kind=.auto + a real ownershipBoundary) is reflected
            // in the immediately-following ownership rebind. Without this order
            // an active id that doesn't change after promotion would leave
            // UsageMonitor pinned to .distantPast.
            self.autoProfileMigrator.runIfNeeded()
            self.rebindHistory(for: self.profileStore.activeProfileId)
            self.rebindUsageMonitorOwnership()
            self.autoProfileCoordinator.start()
            self.cliAccountWatcher.start()
            self.codexAutoProfileCoordinator.start()
            self.codexAccountWatcher.start()
            // Coordinator before watcher so the onChange callback is registered
            // before the watcher's baseline emit fires.
            self.antigravityAutoProfileCoordinator.start()
            self.antigravityProcessWatcher.start()
            self.usage.start()
            self.startCacheScheduler()
            Task { await self.privilegedHelper.refreshStatus() }

            let pollingMode = PollingMode.resolve(
                UserDefaults.standard.string(forKey: AppStorageKeys.generalPollingMode)
            )
            self.lastKnownPollingMode = pollingMode
            AppLog.shared.log(
                "MenuBarViewModel: pollingMode=\(pollingMode.rawValue) " +
                "(open=\(pollingMode.openInterval)s, closed=\(pollingMode.closedInterval)s)",
                level: .info
            )
            let coord = UsageRefreshCoordinator(
                openInterval: pollingMode.openInterval,
                closedInterval: pollingMode.closedInterval,
                now: self.now,
                onTick: { [weak self] in
                    self?.refreshUsageNow()
                }
            )
            self.refreshCoordinator = coord
            coord.start()

            // Live-reload Battery Saver toggle. UserDefaults.didChangeNotification
            // fires for every key, so re-read the polling key and skip when
            // nothing changed; the comparison is also what keeps the rebuild
            // from happening on unrelated AppStorage writes (chart settings,
            // theme, etc.).
            self.pollingModeObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.applyPollingModeFromDefaults() }
            }

            // Pause polling while the Mac sleeps and resume on wake. Two reasons:
            // a) the timer is scheduled on the main runloop, which doesn't fire
            // reliably across sleep/wake — without this the first post-wake tick
            // can be delayed unpredictably; b) batched poll storms the moment a
            // dock-station closes its lid look like burst traffic to a defender.
            // Calling stop()/start() here gives a clean restart with one fresh
            // tick on wake instead.
            #if canImport(AppKit)
            let center = NSWorkspace.shared.notificationCenter
            self.sleepObserver = center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshCoordinator?.stop() }
            }
            self.wakeObserver = center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshCoordinator?.start() }
            }
            #endif

        } else {
            self.rebindHistory(for: self.profileStore.activeProfileId)
            self.rebindUsageMonitorOwnership()
        }

        bindAwakeStateToLog()
    }

    private func applyPollingModeFromDefaults() {
        let current = PollingMode.resolve(
            UserDefaults.standard.string(forKey: AppStorageKeys.generalPollingMode)
        )
        guard current != lastKnownPollingMode else { return }
        lastKnownPollingMode = current
        refreshCoordinator?.setIntervals(
            open: current.openInterval,
            closed: current.closedInterval
        )
        AppLog.shared.log(
            "MenuBarViewModel: pollingMode → \(current.rawValue) " +
            "(open=\(current.openInterval)s, closed=\(current.closedInterval)s)",
            level: .info
        )
    }

    private func bindAwakeStateToLog() {
        // Seed the current state once.
        awakeSessionLog.record(state: awake.state)
        // Re-arm observation; the closure fires once per change.
        observeAwakeStateChange()
    }

    private func observeAwakeStateChange() {
        withObservationTracking {
            _ = self.awake.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.awakeSessionLog.record(state: self.awake.state)
                self.observeAwakeStateChange()
            }
        }
    }

    deinit {
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
        #endif
        if let pollingModeObserver {
            NotificationCenter.default.removeObserver(pollingModeObserver)
        }
        cacheSchedulerTask?.cancel()
    }

    /// Whether the popover is currently visible. Starts closed (the popover
    /// is hidden at launch). Read by the cache-AI eval completion handlers to
    /// decide whether to post a "finished while you were away" notification.
    private(set) var isPopoverOpen = false

    func popoverDidOpen() {
        isPopoverOpen = true
        refreshCoordinator?.popoverDidOpen()
        // Out-of-band poke for the Antigravity watcher so a refresh fired
        // by the SWR gate doesn't race against a stale (or nil) identity
        // from the previous poll tick. Cheap (one ps/lsof spawn) and
        // idempotent — duplicate emits are collapsed by the watcher's
        // equality check. Other providers don't need this because their
        // refresh path doesn't depend on a live process watcher.
        antigravityProcessWatcher.pokeNow()
        // Speed the process poll up to its open cadence while the popover is
        // visible; popoverDidClose backs it off again so idle never spawns
        // pgrep/ps/lsof on the fast interval.
        antigravityProcessWatcher.popoverDidOpen()
        // SWR gate: if the cached summary is still inside the freshness
        // window, skip the opportunistic refresh — the periodic 60s tick
        // will issue the next call. Stops repeated open-close-open from
        // draining the `/api/oauth/usage` token bucket (≈5 calls before
        // 429 with a 300s lockout).
        if MenuBarViewModelSWRGate.shouldSkipRefresh(
            fetchedAt: summary?.fetchedAt,
            now: now(),
            window: freshnessWindow,
            isManual: false
        ) {
            AppLog.shared.log(
                "popoverDidOpen: skipping refresh — summary within freshnessWindow",
                level: .debug
            )
            return
        }
        refreshUsageNow()
    }
    func popoverDidClose() {
        isPopoverOpen = false
        refreshCoordinator?.popoverDidClose()
        antigravityProcessWatcher.popoverDidClose()
    }

    // MARK: Agent process polling + kill

    /// Driven by KeepAwakeTabView.onAppear — runs only while the Awake tab
    /// is visible, consistent with the popover-cadence energy rules.
    func startAgentProcessPolling() {
        guard agentProcessPollTask == nil else { return }
        agentProcessPollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Per-iteration upgrade: if the VM deallocates, the loop
                // exits on the next pass instead of sleeping forever.
                guard let self else { return }
                await self.scanAgentProcessesNow()
                let interval = self.agentProcessPollIntervalNanos
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stopAgentProcessPolling() {
        agentProcessPollTask?.cancel()
        agentProcessPollTask = nil
        // Invalidate any scan currently awaiting its ps result: a stale
        // snapshot landing after stop (or after a stop/start flap) must not
        // clobber what a newer scan wrote.
        agentProcessScanGeneration &+= 1
    }

    /// nil scan (ps failure) keeps the previous snapshot — a transient ps
    /// hiccup must not blank the section.
    func scanAgentProcessesNow() async {
        let generation = agentProcessScanGeneration
        guard let scanned = await agentProcessScanner.scan() else { return }
        guard generation == agentProcessScanGeneration else { return }
        agentProcesses = scanned.sorted {
            if $0.isOrphan != $1.isOrphan { return $0.isOrphan }
            return $0.pid < $1.pid
        }
    }

    /// Kill with automatic escalation, mirroring launchctl semantics:
    /// SIGTERM first (well-behaved processes flush and exit within the
    /// grace window), then SIGKILL if the process is still there — Claude
    /// Code's editor-spawned sessions trap SIGTERM, so without escalation
    /// the rows users most want to clean are unkillable. Any listed row is
    /// killable; the inline confirm is the safety gate.
    ///
    /// Takes the full row captured at confirm time: the confirm can sit
    /// while the 5s poll goes stale and macOS reuses pids, so both signals
    /// re-verify that the pid still carries the same identity. ppid may
    /// differ — the parent can die while the confirm is pending.
    func killAgentProcess(_ target: AgentProcessInfo) async {
        agentProcessKillNotice = nil
        guard await verifiedCurrentRow(for: target) != nil else {
            agentProcessKillNotice = "\(target.commandDisplay) (PID \(target.pid)) is gone or changed; nothing was killed."
            AppLog.shared.log("killAgentProcess pid=\(target.pid) aborted: identity changed", level: .info)
            return
        }
        let pid = target.pid
        switch agentProcessKiller.terminate(pid: pid) {
        case .terminated, .alreadyGone:
            try? await Task.sleep(nanoseconds: agentProcessRescanDelayNanos)
            await scanAgentProcessesNow()
            guard agentProcesses.contains(where: { $0.pid == pid }) else { break } // graceful exit
            // SIGTERM ignored — escalate. Re-verify identity once more:
            // the survivor must still be the same process, not a reuse.
            guard await verifiedCurrentRow(for: target) != nil else { break }
            switch agentProcessKiller.forceTerminate(pid: pid) {
            case .terminated, .alreadyGone:
                try? await Task.sleep(nanoseconds: agentProcessRescanDelayNanos)
                await scanAgentProcessesNow()
                if agentProcesses.contains(where: { $0.pid == pid }) {
                    agentProcessKillNotice = "\(target.commandDisplay) (PID \(pid)) survived SIGKILL — it may be stuck in the kernel."
                }
            case .permissionDenied:
                agentProcessKillNotice = "Permission denied killing \(target.commandDisplay) (PID \(pid))."
            case .failed(let code):
                agentProcessKillNotice = "Failed to kill \(target.commandDisplay) (PID \(pid)) — errno \(code)."
            }
        case .permissionDenied:
            agentProcessKillNotice = "Permission denied killing \(target.commandDisplay) (PID \(pid))."
        case .failed(let code):
            agentProcessKillNotice = "Failed to kill \(target.commandDisplay) (PID \(pid)) — errno \(code)."
        }
        AppLog.shared.log("killAgentProcess pid=\(pid) notice=\(agentProcessKillNotice ?? "ok")", level: .info)
    }

    /// Fresh scan + identity match (command + provider; ppid free to change).
    private func verifiedCurrentRow(for target: AgentProcessInfo) async -> AgentProcessInfo? {
        await scanAgentProcessesNow()
        guard let current = agentProcesses.first(where: { $0.pid == target.pid }),
              current.commandDisplay == target.commandDisplay,
              current.provider == target.provider else { return nil }
        return current
    }

    /// Single source of truth for "is it safe to issue a usage fetch right
    /// now?". `false` means we would either contradict the server's
    /// Retry-After hint (back-off window open) or pile a request on top of
    /// a very recent attempt (throttle floor). Used by `refreshUsageNow`
    /// internally and by the UI for affordance (the Refresh button
    /// disables when this returns false).
    ///
    /// `nowOverride` is for SwiftUI views that pass a `TimelineView`
    /// context date so the button's disabled state re-evaluates each
    /// second without the VM needing to publish a clock-driven update.
    /// Tests pass an explicit date to assert each branch deterministically.
    func canRefreshNow(now nowOverride: Date? = nil) -> Bool {
        let n = nowOverride ?? self.now()
        // Per-provider back-off: a Claude 429 must not gate Antigravity
        // (loopback, no rate limit) or Codex (separate gateway). The
        // active provider's floor is what governs whether the refresh
        // button is enabled. When no active profile, fall back to the
        // global max — there's nothing meaningful to gate anyway.
        if let providerID = profileStore.activeProfile?.providerID {
            if let until = refreshCoordinator?.backoffUntil(for: providerID),
               until > n { return false }
        } else if let until = refreshCoordinator?.backoffUntil, until > n {
            return false
        }
        if let last = lastFetchAttemptAt,
           n.timeIntervalSince(last) < refreshThrottle { return false }
        return true
    }

    /// Creates a new profile, writes its credential to Keychain, and switches
    /// the active profile to the new one. Throws if persistence fails.
    func addProfile(
        name: String,
        credential: Credential,
        authMethod: AuthMethodKind,
        subscriptionPlan: String? = nil,
        subscriptionCreatedAt: Date? = nil,
        email: String? = nil
    ) throws {
        let profile = Profile(
            name: name,
            authMethod: authMethod,
            subscriptionPlan: subscriptionPlan,
            subscriptionCreatedAt: subscriptionCreatedAt,
            email: email
        )
        try credentialStore.write(credential, for: profile.id)
        try profileStore.add(profile)
        try profileStore.setActive(id: profile.id)
    }

    /// Finds an existing profile representing the same Anthropic account.
    /// Match key is email OR organizationId — either is enough because both
    /// are stable per-account identifiers, and either may be nil on legacy
    /// profiles. Email is compared case-insensitively.
    func findMatchingProfile(providerID: ProviderID = .claude,
                            email: String?,
                            orgId: String?) -> Profile? {
        for profile in profileStore.profiles where profile.providerID == providerID {
            if let email,
               let existingEmail = profile.email,
               email.caseInsensitiveCompare(existingEmail) == .orderedSame {
                return profile
            }
            if let orgId,
               let existingOrg = profile.organizationId,
               orgId == existingOrg {
                return profile
            }
        }
        return nil
    }

    /// Replaces the credentials and auth method of an existing profile in
    /// place. Profile id, name, and history are preserved; previously-nil
    /// `email` / `organizationId` are backfilled from the supplied values.
    /// `sessionKeyExpiresAt` is set when `newAuthMethod == .sessionKey` and
    /// cleared otherwise. The profile is set active.
    @discardableResult
    func replaceCredentials(
        profileId: UUID,
        newCredential: Credential,
        newAuthMethod: AuthMethodKind,
        expiry: Date? = nil,
        email: String? = nil,
        organizationId: String? = nil,
        subscriptionPlan: String? = nil,
        subscriptionCreatedAt: Date? = nil
    ) throws -> Profile {
        guard let existing = profileStore.profiles.first(where: { $0.id == profileId }) else {
            throw NSError(domain: "MenuBarViewModel", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Profile not found"
            ])
        }
        var updated = existing
        updated.authMethod = newAuthMethod
        updated.sessionKeyExpiresAt = (newAuthMethod == .sessionKey) ? expiry : nil
        if updated.email == nil, let email { updated.email = email }
        if updated.organizationId == nil, let organizationId {
            updated.organizationId = organizationId
        }
        // subscriptionPlan: overwrite when supplied (web data is the
        // freshest source of truth for sessionKey conversions; CLI keychain
        // value may be stale or never present). Do NOT backfill-only here —
        // a stale "Pro" from a prior conversion shouldn't shadow a fresh
        // "Team" probe.
        if let subscriptionPlan {
            updated.subscriptionPlan = subscriptionPlan
        }
        // subscriptionCreatedAt: same overwrite policy as plan — fresh
        // bootstrap probe is more authoritative than whatever the CLI
        // keychain or earlier sessionKey-add captured.
        if let subscriptionCreatedAt {
            updated.subscriptionCreatedAt = subscriptionCreatedAt
        }
        try credentialStore.write(newCredential, for: updated.id)
        try profileStore.updateProfile(updated)
        try profileStore.setActive(id: updated.id)
        // Force a refresh even when setActive didn't change the active id
        // (re-auth on the currently-active profile): the +
        // removeDuplicates() pipeline skips the sink for same-value emits,
        // so rebindHistory wouldn't fire and the new credential's data
        // would never reach the UI until the next coord tick or manual
        // Refresh. This is what made Web Sign-In require a manual Reload
        // to see the correct chart.
        //
        // Clear the throttle so a recent fetch on the prior credential
        // doesn't gate this re-auth follow-up.
        lastFetchAttemptAt = nil
        refreshUsageNow()
        return updated
    }

    /// Outcome of a user-initiated `refreshProfileMetadata(for:)` call.
    /// Surfaced to `ProfileDetailView` so it can render the inline banner.
    enum RefreshResult: Equatable {
        case updated
        case noChange
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case offline
        case otherError(String)
    }

    /// Refreshes the profile's metadata through its provider, applying the
    /// diff to the store, and surfaces the outcome so the detail-sheet Refresh
    /// button can render a banner. Dispatches via the registry — the shell
    /// never branches on a concrete provider. Each provider re-uses the same
    /// persistence path its background sync uses, so a manual Refresh and the
    /// background refresh cannot diverge.
    @MainActor
    func refreshProfileMetadata(for profileId: UUID) async -> RefreshResult {
        guard let profile = profileStore.profiles.first(where: { $0.id == profileId }) else {
            return .otherError("Profile no longer exists")
        }
        guard let provider = registry.provider(for: profile.providerID) else {
            return .otherError("Unknown provider: \(profile.providerID.rawValue)")
        }
        let credential: Credential
        do {
            guard let stored = try credentialStore.read(for: profileId) else {
                return .otherError("No credential stored for this profile")
            }
            credential = stored
        } catch {
            return .otherError(error.localizedDescription)
        }
        do {
            let changed = try await provider.refreshProfileMetadata(for: profile, credential: credential)
            return changed ? .updated : .noChange
        } catch let error as ProviderMetadataRefreshError {
            switch error {
            case .unauthorized:              return .unauthorized
            case .rateLimited(let retry):    return .rateLimited(retryAfter: retry)
            case .offline:                   return .offline
            case .identityMismatch(let msg): return .otherError(msg)
            case .other(let msg):            return .otherError(msg)
            }
        } catch {
            return .otherError(error.localizedDescription)
        }
    }

    /// Re-instantiates the active profile's `UsageHistoryStore` so a
    /// retention-cap change (written to UserDefaults by the Data &
    /// Storage tab) takes effect on the next append. No-op when no
    /// profile is active.
    func reloadHistoryStores() {
        rebindHistory(for: profileStore.activeProfileId)
    }

    private func rebindHistory(for profileId: UUID?) {
        // Bump generation first — any in-flight refresh from before this
        // point is now stale and must not be allowed to commit UI state.
        refreshGeneration &+= 1
        // Always reset transient state so prior profile's auth/error never
        // bleeds into the new one's view.
        lastError = nil
        // Clear `summary` here, not only in the per-branch resets below:
        // it carries the prior provider/account's `primary`/`secondary`
        // buckets that the menu-bar icon, DisplayMenuBarCard, and the
        // UsageTab fallback all read directly via `vm.summary`. Leaving it
        // populated after a sign-out or fresh-profile switch surfaced old
        // quota numbers as if they belonged to the newly bound profile.
        // The next successful fetch repopulates it; until then the UI
        // must render the loading / signed-out state, not stale data.
        self.summary = nil

        guard let id = profileId else {
            historyStore = nil
            history = []
            snapshot = nil
            lastFetchedAt = nil
            // No profile bound → not refreshing, not switching. Empty state.
            authState = .authenticated
            isSwitchingProfile = false
            return
        }
        // Resolve the profile from the id we received, NOT via
        // profileStore.activeProfileId. When this sink runs as the
        // willSet emit from `ProfileStore.add` setting activeProfileId on
        // the first profile, the property has not yet committed — reading
        // it would yield nil and skip the refresh. profiles[] *was* updated
        // before the activeProfileId assignment, so an id-keyed lookup
        // works in both willSet and post-commit cases. Symptom of the
        // stale read: spinner stuck after the very first add-profile until
        // the user toggled the popover (which fires activeProfileId-reading
        // refreshUsageNow once the willSet had committed).
        guard let profile = profileStore.profiles.first(where: { $0.id == id }) else {
            historyStore = nil
            history = []
            snapshot = nil
            lastFetchedAt = nil
            authState = .authenticated
            isSwitchingProfile = false
            return
        }
        authState = .refreshing
        let store = UsageHistoryStore(historyFile: historyFileProvider(id))
        historyStore = store
        history = (try? store.load()) ?? []
        let cached = profile.lastSnapshot
        if let cached {
            self.snapshot = cached
            self.lastFetchedAt = cached.fetchedAt
        } else {
            // Brand-new profile: clear stale stub so the popover doesn't lie.
            self.snapshot = nil
            self.lastFetchedAt = nil
        }
        // Show the loading placeholder only when there's no cached snapshot
        // to fall back on. Profiles with cache render their last-known data
        // immediately and refresh in the background — far snappier than
        // hiding the chart for the full network round-trip.
        // (The earlier `&& self.summary == nil` clause was redundant once
        // `summary` is cleared at the top of this function.)
        isSwitchingProfile = (cached == nil)
        // Clear the prior profile's throttle so the new profile's first
        // fetch is not gated by it. Back-off is NOT cleared — a server
        // hint applies to our IP, not the profile identity.
        lastFetchAttemptAt = nil
        // SWR gate: if the new profile's last successful fetch is still
        // inside the freshness window, skip the auto-refresh. Stops the
        // A→B→A→B switcher back-and-forth from draining the
        // /api/oauth/usage token bucket. `profile.lastFetchedAt` is
        // provider-agnostic — written for both Claude and Codex paths
        // on every successful commit.
        //
        // Renderable-fallback guard: rebindHistory cleared `summary` at
        // the top, so for the skip to be visually safe the profile must
        // have a renderable cache to fall back on. Claude has
        // `lastSnapshot` (a legacy UsageSnapshot the chart resolver
        // adapts into a summary). Codex has no equivalent persisted
        // snapshot — without one, skipping the refresh leaves the chart
        // resolving to `.empty`. So we only apply the skip when there
        // is a Claude `lastSnapshot` available; Codex switches always
        // refresh today. (Persisting a provider-agnostic summary so
        // Codex can also benefit from SWR is a follow-up.)
        let hasRenderableFallback = (profile.providerID == .claude) && (profile.lastSnapshot != nil)
        if hasRenderableFallback,
           MenuBarViewModelSWRGate.shouldSkipRefresh(
               fetchedAt: profile.lastFetchedAt,
               now: now(),
               window: freshnessWindow,
               isManual: false
           ) {
            AppLog.shared.log(
                "rebindHistory: skipping refresh — profile.lastFetchedAt within freshnessWindow",
                level: .debug
            )
            authState = .authenticated
            isSwitchingProfile = false
            return
        }
        refreshUsageNow(profile: profile)
    }

    /// Pre-populate `summary` with a freshly-cached value from the profile
    /// switcher's coordinator at switch time. The switcher fetches per-row
    /// utilization on expand, so by the time the user clicks a non-active
    /// row we already hold its summary; without this seam, the regular
    /// `onActiveProfileChange` flow nukes `summary` and shows the
    /// "Refreshing…" placeholder until the next network round-trip lands.
    ///
    /// Provider-ID guard prevents a Codex-cached summary from ever
    /// surfacing under a Claude-active profile (or vice versa); the caller
    /// is expected to invoke this right AFTER `setActive`, when
    /// `profileStore.activeProfile` already reflects the new profile.
    func adoptPreloadedSummary(_ s: ProviderUsageSummary) {
        guard let active = profileStore.activeProfile,
              active.providerID == s.providerID else { return }
        self.summary = s
        rememberSummary(s, for: active.id)
        self.isSwitchingProfile = false
    }

    private func rememberSummary(_ summary: ProviderUsageSummary, for profileID: UUID) {
        lastSummaryByProfile[profileID] = summary
    }

    private func rebindUsageMonitorOwnership() {
        guard let p = profileStore.activeProfile else {
            usage.ownership = nil
            return
        }
        usage.ownership = .init(
            profileId: p.id,
            boundary: p.ownershipBoundary ?? .distantPast
        )
    }

    func refreshUsageNow() {
        guard let activeId = profileStore.activeProfileId,
              let profile = profileStore.profiles.first(where: { $0.id == activeId }) else { return }
        refreshUsageNow(profile: profile)
    }

    private func refreshUsageNow(profile: Profile) {
        guard canRefreshNow() else {
            AppLog.shared.log(
                "refreshUsageNow skipped: gate closed "
                + "(backoffUntil=\(String(describing: refreshCoordinator?.backoffUntil)), "
                + "lastAttempt=\(String(describing: lastFetchAttemptAt)))",
                level: .debug
            )
            return
        }
        // The throttle measures invocations, not outbound API calls. The
        // stamp lands BEFORE the spawned Task runs, so a refresh that the
        // async `refresh(profile:)` later denies via `guardRefresh`
        // (CLI/profile identity mismatch) still consumes the 10s floor.
        // This is intentional: stamping here protects against burst-click
        // / popover-open + coord-tick races. Moving the stamp inside the
        // Task after `guardRefresh` would let N concurrent calls spawn N
        // Tasks before any of them stamped. Users in a CLI-identity-
        // mismatch state will see Refresh briefly throttled even though
        // no network attempt fired — acceptable trade-off vs. the burst
        // protection.
        lastFetchAttemptAt = now()
        // Bump generation on every external trigger (popover open, coord
        // tick, manual Refresh, replaceCredentials follow-up). Without this
        // bump, two refresh Tasks spawned in quick succession share the
        // same generation and both pass canCommitToUI() — last-writer-wins
        // races stale data into the UI on Web Sign-In, where the user has
        // to click Refresh manually to recover. With the bump, any Task in
        // flight when a newer trigger fires gets invalidated at commit
        // time so only the freshest data lands.
        refreshGeneration &+= 1
        Task { await self.refresh(profile: profile) }
    }

    /// Returns the on-disk history store for the given profile. When the
    /// profile is the currently-active one we reuse the bound instance (which
    /// already holds any unflushed in-memory state). Otherwise we build a
    /// fresh store tied to the profile's id — this lets an in-flight refresh
    /// complete its writes against the *correct* profile even after the user
    /// has switched away.
    /// Snapshot commits use this looser gate instead of the strict
    /// generation check. The strict gate would drop a valid Task result
    /// whenever an opportunistic trigger (popoverDidOpen, coord tick)
    /// bumped `refreshGeneration` while the Task was awaiting the
    /// network. Freshness comparison preserves the original Web Sign-In
    /// race fix (newer `fetchedAt` always wins) without rejecting an
    /// in-flight Task's result just because a later trigger fired.
    func canCommitSnapshot(_ snap: UsageSnapshot, forProfileId id: UUID) -> Bool {
        guard id == profileStore.activeProfileId else { return false }
        guard let current = snapshot else { return true }
        return snap.fetchedAt > current.fetchedAt
    }

    private func historyStoreForRefresh(profile: Profile) -> UsageHistoryStore {
        if profile.id == profileStore.activeProfileId,
           let h = historyStore {
            return h
        }
        return UsageHistoryStore(historyFile: historyFileProvider(profile.id))
    }

    /// Liveness gate for notifications. A profile is "live" when its
    /// provider's signal — CLI session email match for Claude/Codex,
    /// running app for Antigravity — agrees with this profile. Matches
    /// the popover switcher's badge so Settings ▸ Notifications shows
    /// the same set of accounts that can actually trigger an alert.
    private func profileIsLive(_ profile: Profile) -> Bool {
        ProfileSwitcherCard.isLive(
            profile: profile,
            claudeCLIEmail: cliAccountWatcher.current?.email,
            codexCLIEmail: codexAccountWatcher.current?.email,
            antigravityProcessAlive: antigravityProcessWatcher.current != nil
        )
    }

    private func refresh(profile: Profile) async {
        let historyStore = historyStoreForRefresh(profile: profile)
        let generation = refreshGeneration

        // Only commit UI state when both predicates hold:
        //   1. profile.id is still the active one (race fix from earlier)
        //   2. our captured generation is still the latest (prevents an
        //      older Task from clobbering a newer switch's data — even
        //      when both Tasks fetched for the same profile)
        func canCommitToUI() -> Bool {
            profile.id == profileStore.activeProfileId
                && generation == refreshGeneration
        }

        func canCommitSnapshot(_ snap: UsageSnapshot) -> Bool {
            self.canCommitSnapshot(snap, forProfileId: profile.id)
        }

        guard autoProfileCoordinator.guardRefresh(profile: profile) else {
            AppLog.shared.log(
                "MenuBarViewModel.refresh: guardRefresh denied for profile=\(profile.id) — skipping",
                level: .info
            )
            if canCommitToUI() {
                authState = .authenticated
                isSwitchingProfile = false
            }
            return
        }

        if canCommitToUI() {
            authState = .refreshing
            // Clear any prior error so a previous tick's lastError doesn't
            // stick around once this refresh succeeds. If we hit an error
            // again later, the catch blocks will reset it.
            lastError = nil
        }

        do {
            guard let credential = try credentialStore.read(for: profile.id) else {
                if canCommitToUI() {
                    authState = .expired
                    isSwitchingProfile = false
                }
                return
            }

            // Route through the provider registry. ClaudeProvider owns the
            // freshen / 401-retry / endpoint-branching that used to live
            // inline here. The shell only handles UI/commit orchestration.
            guard let provider = registry.provider(for: profile.providerID) else {
                AppLog.shared.log(
                    "MenuBarViewModel: no provider registered for \(profile.providerID.rawValue) — skipping refresh",
                    level: .warn
                )
                if canCommitToUI() {
                    lastError = "Unknown provider: \(profile.providerID.rawValue)"
                    authState = .authenticated
                    isSwitchingProfile = false
                }
                return
            }

            let summary = try await provider.fetchUsage(credential: credential, profile: profile)

            // RetryAfter from the provider — push the coordinator out so
            // the next tick respects the server's back-off hint. Scoped
            // to the provider that returned it (per-provider floors).
            if let retryAfter = summary.retryAfter, retryAfter > 0 {
                refreshCoordinator?.applyRetryAfter(retryAfter, for: summary.providerID)
            }

            // Degraded-but-successful guard. A provider can return HTTP 200
            // with an empty body — Codex's `wham/usage` intermittently sends
            // `rate_limit: null` — which decodes to a valid summary whose
            // bars are both empty. If the active profile already has a
            // same-provider summary with data, treat the empty result as a
            // transient hiccup: settle the auth/refresh state so the footer
            // doesn't sit on "Refreshing…", but keep the existing summary,
            // history, and lastFetchedAt rather than blanking the bars and
            // the menu-bar badge. Throwing errors already preserve the
            // summary in the catch blocks below; this closes the one path
            // where a non-throwing fetch would overwrite good data.
            if ProviderUsageSummary.shouldRetain(previous: self.summary, over: summary) {
                AppLog.shared.log(
                    "MenuBarViewModel.refresh: dropped empty \(summary.providerID.rawValue) fetch — retained last good summary",
                    level: .info
                )
                if canCommitToUI() {
                    authState = .authenticated
                    rateLimitedUntil = nil
                    consecutive429Count = 0
                    isSwitchingProfile = false
                }
                return
            }

            if let snap = summary.payload as? UsageSnapshot {
                // Claude path: UsageSnapshot payload — write history entry,
                // patch profile cache, and commit using the freshness gate.
                let entry = UsageHistoryEntry(
                    at: snap.fetchedAt,
                    fiveHour: snap.fiveHour.utilization,
                    sevenDay: snap.sevenDay.utilization
                )
                try? historyStore.append(entry)

                let currentFive = snap.fiveHour.utilization ?? 0

                // Re-read the latest profile from the store before patching so
                // any concurrent edit (e.g. email backfill) survives.
                if var latest = profileStore.profiles.first(where: { $0.id == profile.id }) {
                    latest.lastFetchedAt = snap.fetchedAt
                    latest.lastSnapshot = snap
                    latest.lastSessionPercentage = currentFive
                    try? profileStore.updateProfile(latest)
                }

                // Snapshot commit uses the freshness-based gate so an
                // in-flight Task's valid result lands even when an opportunistic
                // trigger has already bumped generation. profile.id mismatch
                // and "older than current" are still rejected.
                if canCommitSnapshot(snap) {
                    let previousSummary = self.summary
                    self.snapshot = snap
                    self.summary = summary
                    rememberSummary(summary, for: profile.id)
                    self.lastFetchedAt = snap.fetchedAt
                    self.authState = .authenticated
                    self.rateLimitedUntil = nil
                    self.consecutive429Count = 0
                    self.history.append(entry)
                    self.isSwitchingProfile = false

                    // Re-read profile in case a concurrent edit (notifications toggle,
                    // org-id backfill) updated it during the await above.
                    let latestProfile = profileStore.profiles.first(where: { $0.id == profile.id }) ?? profile
                    if profileIsLive(latestProfile) {
                        let intents = notificationDispatcher.evaluate(
                            profile: latestProfile,
                            settings: notificationSettingsStore.value,
                            current: summary,
                            previous: previousSummary,
                            now: Date()
                        )
                        if !intents.isEmpty {
                            Task { await notificationDispatcher.dispatch(intents) }
                        }
                    }
                } else if canCommitToUI() {
                    authState = .authenticated
                    isSwitchingProfile = false
                }
            } else {
                // Non-Claude provider (e.g. Codex) — payload is provider-specific
                // and not a UsageSnapshot. Commit summary directly; the legacy
                // snapshot mirror stays nil and the chart reads summary.primary.

                if canCommitToUI() {
                    let previousSummary = self.summary
                    self.snapshot = nil
                    self.summary = summary
                    rememberSummary(summary, for: profile.id)
                    self.lastFetchedAt = summary.fetchedAt
                    self.authState = .authenticated
                    self.rateLimitedUntil = nil
                    self.consecutive429Count = 0
                    self.isSwitchingProfile = false

                    // Patch the profile's subscriptionPlan from the typed
                    // payload AFTER the gate accepts the commit. If we patched
                    // earlier and a stale in-flight refresh (active profile
                    // changed mid-fetch) was rejected by the gate, we'd still
                    // persist plan + lastFetchedAt onto the old profile, which
                    // is wrong: the data may belong to a different account
                    // entirely once the Codex CLI has switched users.
                    if let codex = summary.payload as? CodexUsageSnapshot,
                       var latest = profileStore.profiles.first(where: { $0.id == profile.id }) {
                        let planLabel = PlanFormatter.format(codex.planType)
                        if latest.subscriptionPlan != planLabel || latest.lastFetchedAt != summary.fetchedAt {
                            latest.subscriptionPlan = planLabel
                            latest.lastFetchedAt = summary.fetchedAt
                            try? profileStore.updateProfile(latest)
                        }
                    }

                    if let primary = summary.primary, let secondary = summary.secondary {
                        let entry = UsageHistoryEntry(
                            at: summary.fetchedAt,
                            fiveHour: primary.utilization,
                            sevenDay: secondary.utilization
                        )
                        try? historyStore.append(entry)
                        self.history.append(entry)
                    }

                    // Provider-agnostic: evaluate the provider's credit cycle
                    // from this fetch against the profile's persisted last
                    // reading. Codex returns nil here (no-op); Antigravity
                    // compares the real-API wallet (never the SQLite fallback)
                    // against a stable ceiling, persisting the rolling reading
                    // and advancing the observed reset anchor on a real reset.
                    if let provider = registry.provider(for: profile.providerID),
                       var latest = profileStore.profiles.first(where: { $0.id == profile.id }),
                       let eval = provider.evaluateCreditCycle(summary: summary, profile: latest, now: Date()) {
                        var changed = false
                        if let reset = eval.resetDetectedAt,
                           let adopted = RenewalEstimator.adopt(detected: reset,
                                                                over: latest.observedCreditResetAt) {
                            latest.observedCreditResetAt = adopted
                            changed = true
                            AppLog.shared.log(
                                "MenuBarViewModel.refresh: observed credit reset \(adopted) for \(profile.providerID.rawValue)",
                                level: .info
                            )
                        }
                        if latest.lastCreditWallet != eval.lastWallet
                            || latest.lastCreditCeiling != eval.lastCeiling {
                            latest.lastCreditWallet = eval.lastWallet
                            latest.lastCreditCeiling = eval.lastCeiling
                            changed = true
                        }
                        if changed { try? profileStore.updateProfile(latest) }
                    }

                    let latestProfile = profileStore.profiles.first(where: { $0.id == profile.id }) ?? profile
                    if profileIsLive(latestProfile) {
                        let intents = notificationDispatcher.evaluate(
                            profile: latestProfile,
                            settings: notificationSettingsStore.value,
                            current: summary,
                            previous: previousSummary,
                            now: Date()
                        )
                        if !intents.isEmpty {
                            Task { await notificationDispatcher.dispatch(intents) }
                        }
                    }
                }
            }
        } catch ClaudeAPIClient.APIError.unauthorized {
            if canCommitToUI() {
                authState = .expired
                lastError = profile.providerID == .codex
                    ? "Codex CLI session expired — run `codex login` to refresh."
                    : "Claude CLI session expired — run claude login to refresh."
                isSwitchingProfile = false
            }
        } catch ClaudeAPIClient.APIError.rateLimited(let retryAfter) {
            // Server is throttling us — both the cliSync (oauth/usage) and
            // sessionKey (claude.ai/api/usage) paths surface 429 here. Body
            // is unusable in either case, so we keep the prior cached
            // snapshot and push the next tick out. Not surfaced as a
            // user-facing error.
            //
            // Two regimes:
            //  - Server sent a usable Retry-After: honor it verbatim. The
            //    counter isn't touched — the server is being explicit, and
            //    we don't want a single 30s explicit hint to bump us into
            //    a longer fallback on the next silent 429.
            //  - Server omitted (or sent 0): use an exponential schedule
            //    of 60s, 120s, 240s, 300s (cap). One transient 429 hides
            //    the UI for a minute, not five; a persistent throttle
            //    still settles at the same 5-minute ceiling as before.
            let backoff: TimeInterval
            if let server = retryAfter, server > 0 {
                backoff = server
            } else {
                consecutive429Count += 1
                backoff = Self.fallbackBackoff(forConsecutiveCount: consecutive429Count)
            }
            refreshCoordinator?.applyRetryAfter(backoff, for: profile.providerID)
            // Mirror the back-off into the VM-level field that drives the
            // RateLimitBanner. This is intentionally OUTSIDE canCommitToUI:
            // the refresh gate (canRefreshNow) reads coord.backoffUntil
            // regardless of which generation produced it, so the matching
            // banner must surface too — otherwise a stale-generation 429
            // disables the Refresh button silently with no explanation.
            rateLimitedUntil = now().addingTimeInterval(backoff)
            AppLog.shared.log(
                "MenuBarViewModel: 429 on \(profile.authMethod) path, backing off \(Int(backoff))s (consecutive=\(consecutive429Count))",
                level: .info
            )
            if canCommitToUI() {
                isSwitchingProfile = false
                // Credential is still valid — server is just throttling. Without
                // this reset, authState stays at the .refreshing it was set to
                // at the top of refresh(), and the footer's "Refreshing…"
                // spinner sticks forever.
                authState = .authenticated
                // Leave snapshot/lastFetchedAt as-is so the UI keeps the last
                // good values; RateLimitBanner surfaces why refresh stalled.
            }
        } catch {
            AppLog.shared.log(
                "MenuBarViewModel.refresh: fall-through error for \(profile.providerID.rawValue) profile \(profile.id.uuidString.prefix(8)): \(String(describing: error))",
                level: .error
            )
            if canCommitToUI() {
                lastError = String(describing: error)
                authState = .authenticated
                isSwitchingProfile = false
            }
        }
    }

    /// Exponential fallback schedule for 429s that arrive without a usable
    /// Retry-After header. Schedule: 60, 120, 240, then capped at 300s.
    /// `count` is 1-indexed (the n-th consecutive silent 429).
    /// `nonisolated` because it's a pure function — keeps the test suite
    /// off the main actor.
    nonisolated static func fallbackBackoff(forConsecutiveCount count: Int) -> TimeInterval {
        guard count >= 1 else { return 60 }
        // Int shift (capped) avoids overflow and pow() type-inference noise.
        let raw = 60.0 * Double(1 << min(count - 1, 30))
        return min(raw, 300)
    }

    // MARK: - Awake actions (forwarded to supervisor)

    @discardableResult
    func awakeForceStart() -> Result<Void, AwakeBlockReason> {
        awake.forceStart(
            options: awake.config.flags,
            timeout: awake.config.forceTimeout.seconds.map(TimeInterval.init)
        )
    }

    func awakeForceStop() {
        awake.forceStop()
    }

    /// Forces an immediate UsageMonitor tick. Used by the popover's
    /// "Refresh" button so the user doesn't wait for the next 5s tick.
    func forceRefresh() {
        usage.tick()
    }

    // MARK: - Cache (scan / clean / AI eval)

    /// Runs `CacheCleaner.scan` against every row's path off the main actor
    /// and patches `sizeBytes` / `exists` back into the matching rows. Gated
    /// by the user's `scanInterval` unless `force` is true — opening the
    /// Cache tab fires this with `force: false`, the Rescan button with
    /// `force: true`.
    ///
    /// Concurrency: `CacheCleaner.scan` enumerates large directories
    /// synchronously (Xcode DerivedData can take 10–30s), so it MUST run off
    /// `MainActor`. We capture the URL list, hop to a detached utility task
    /// for the scan, then hop back to map results into rows.
    func cacheScan(force: Bool) async {
        guard !cacheState.isScanning else { return }

        if !force, let last = cacheState.lastScannedAt {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < cacheState.settings.scanInterval.seconds {
                AppLog.shared.log(
                    "cacheScan skipped — last scan \(Int(elapsed))s ago < interval \(Int(cacheState.settings.scanInterval.seconds))s",
                    level: .info
                )
                return
            }
        }

        let targets = cacheState.rows.map(\.path)
        cacheState.isScanning = true

        // Enumerate on a background GCD queue via `OffMain.run`. The directory
        // walk (tens of thousands of files under ~/.cache + Library/Caches)
        // must never touch the main thread. `Task.detached { await
        // scanConcurrent() }` does NOT achieve that: the target builds with
        // SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so `scanConcurrent` is an
        // implicitly-@MainActor async method, and awaiting it from a detached
        // task hops back to the main actor — the walk ran on main (measured:
        // ~46% of main-thread samples in makeEntry/getattrlistbulk). A
        // synchronous `scan()` inside a GCD closure runs genuinely off-main.
        // We trade live per-path streaming for one batched apply when the scan
        // finishes; the popover stays responsive.
        var totalFiles = 0
        var totalBytes = 0
        var entriesProcessed = 0
        let entries = await OffMain.run { CacheCleaner(targets: targets).scan().entries }
        // Skip system rows: the unprivileged walk reports them as 0 bytes
        // (root-only), which would drop them from the popover until the
        // privileged size query below restores them — a disappear/reappear
        // flicker. The privileged pass (`applyingSystemSizes`) owns their size.
        cacheState.rows = Self.applyingScanEntries(cacheState.rows, entries: entries)
        for entry in entries {
            totalFiles += entry.fileCount
            totalBytes += entry.bytes
            entriesProcessed += 1
            if entry.truncated {
                AppLog.shared.log(
                    "cacheScan: enumeration of \(entry.path.path) hit the time budget — reported size is a floor, not exact",
                    level: .warn)
            }
        }

        // System caches (e.g. icon services) are root-readable only; the
        // unprivileged CacheCleaner walk above can't size them. Ask the root
        // helper when it's enabled — silent, no prompt. When it isn't enabled,
        // the rows simply keep whatever size they had.
        let systemIDs = Self.splitCleanTargets(
            cacheState.rows.filter(\.isSystem).map(\.path)).system
        if !systemIDs.isEmpty {
            let sizes = await privilegedHelper.systemCacheSizes(identifiers: systemIDs)
            if !sizes.isEmpty {
                cacheState.rows = Self.applyingSystemSizes(cacheState.rows, sizes: sizes)
                totalBytes += sizes.values.reduce(0) { $0 + Int($1) }
            }
        }

        let now = Date()
        cacheState.lastScannedAt = now
        cacheState.nextScanAt = now.addingTimeInterval(cacheState.settings.scanInterval.seconds)
        cacheState.isScanning = false
        // Save once at the end rather than per-entry; intermediate
        // sizes during an in-flight scan would write the file 15+ times.
        saveCacheState()

        AppLog.shared.log(
            "cacheScan completed — \(totalFiles) files / \(totalBytes) bytes across \(entriesProcessed) paths",
            level: .info
        )
    }

    /// Rescan trigger from the popover footer button. Always forces a fresh
    /// scan regardless of the interval gate.
    func cacheRescan() {
        Task { await cacheScan(force: true) }
    }

    /// Kicks off the background scheduler loop. Each tick:
    ///   1. Sleeps for `scanInterval` (cancellable — Task.sleep throws on
    ///      cancel, which we use to gracefully end the loop).
    ///   2. Force-scans every tracked path.
    ///   3. If `settings.isEnabled` and the new total exceeds `globalCapBytes`,
    ///      auto-trashes every auto-on row with content. No NSAlert here:
    ///      auto-clean is opted into per-row via the toggle + master switch,
    ///      a background interactive prompt would defeat the purpose.
    ///
    /// Skipped entirely in `.hostedTests` so unit tests don't fight a real
    /// background Timer.
    private func startCacheScheduler() {
        cacheSchedulerTask?.cancel()
        // `@MainActor` on the Task body lets us read `cacheState` and call
        // `cacheTick` without per-property `await` hops. `Task.sleep` still
        // suspends rather than blocking, so the main run loop stays free.
        // `[weak self]` so a retained Task can't keep the VM alive past
        // deinit; we rebind via a uniquely-named `vm` to dodge Swift 6's
        // "captured var self" warning.
        cacheSchedulerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let vm = self else { return }
                let interval = vm.cacheState.settings.scanInterval.seconds
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return // cancelled
                }
                if Task.isCancelled { return }
                guard let vm2 = self else { return }
                await vm2.cacheTick()
            }
        }
    }

    /// One scheduler iteration. Public-internal so a future test harness
    /// could exercise the decision without waiting for `Task.sleep`.
    @MainActor
    func cacheTick() async {
        // Sweep stale Trash items before the scan/clean step, so disk
        // usage shown after the scan reflects post-purge state.
        await purgeOldTrashedItemsIfEnabled()

        await cacheScan(force: true)

        guard cacheState.settings.isEnabled else {
            AppLog.shared.log("Scheduler tick: auto-clean disabled, skipping clean step", level: .info)
            return
        }

        let totalBytes = cacheState.rows.reduce(0) { $0 + $1.sizeBytes }
        let cap = cacheState.settings.globalCapBytes
        guard totalBytes > cap else {
            AppLog.shared.log("Scheduler tick: \(totalBytes) bytes ≤ cap \(cap), no clean needed", level: .info)
            return
        }

        let overage = totalBytes - cap
        let targets = Self.chooseAutoCleanTargets(
            from: cacheState.rows,
            byteOverage: overage
        )
        guard !targets.isEmpty else {
            AppLog.shared.log(
                "Scheduler tick: over cap by \(overage)B but no eligible auto-on rows (risky verdicts skipped, others off) — user-only cleanup required",
                level: .warn
            )
            return
        }

        AppLog.shared.log(
            "Scheduler tick: over cap by \(overage)B — auto-cleaning \(targets.count) folders (smallest subset)",
            level: .info
        )
        await cacheClean(targets: targets, surfaceErrors: false)
    }

    /// Permanent-delete tracked Trash items older than the user's
    /// configured threshold (`settings.autoEmptyTrashAfterDays`). No-op
    /// when the threshold is 0 (the default) — items linger in Trash
    /// until the user empties Finder Trash manually.
    ///
    /// Only touches items Kwota itself put in Trash (entries in
    /// `cacheState.trashedItems`). The user's other trashed files are
    /// off-limits. Items the user has manually emptied or restored show
    /// up as "not found at trashedURLPath" — we drop them from tracking
    /// without erroring.
    ///
    /// The FileManager IO runs on a detached utility task. A user who has
    /// accumulated many trashed items would otherwise stall the popover's
    /// main run loop while the sweep ran.
    ///
    /// We deliberately don't sum bytes for the log line:
    /// `attributesOfItem(atPath:)[.size]` returns the directory inode's
    /// own size (typically <1 KB) rather than the recursive content size,
    /// so it would have been misleading. Item count is the accurate
    /// signal.
    func purgeOldTrashedItemsIfEnabled() async {
        let days = cacheState.settings.autoEmptyTrashAfterDays
        guard days > 0, !cacheState.trashedItems.isEmpty else { return }

        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86_400)
        let items = cacheState.trashedItems

        let outcome = await OffMain.run { () -> (keep: [CachePersistedState.TrashedItem], purgedCount: Int) in
            let fm = FileManager.default
            var purgedCount = 0
            var keep: [CachePersistedState.TrashedItem] = []
            for item in items {
                if item.trashedAt > cutoff {
                    keep.append(item)
                    continue
                }
                let url = URL(fileURLWithPath: item.trashedURLPath)
                do {
                    try fm.removeItem(at: url)
                    purgedCount += 1
                } catch CocoaError.fileNoSuchFile {
                    // User already emptied or restored — fine, drop it from tracking.
                } catch {
                    AppLog.shared.log(
                        "purgeOldTrashedItemsIfEnabled: removeItem failed for \(url.path): \(error)",
                        level: .warn
                    )
                    // Keep tracking so the next purge tick retries. A
                    // permanently stuck file accumulates retry attempts (one
                    // per purge interval), which is acceptable for a
                    // debug-tier auto-empty surface.
                    keep.append(item)
                }
            }
            return (keep, purgedCount)
        }

        if cacheState.trashedItems.count != outcome.keep.count {
            cacheState.trashedItems = outcome.keep
            saveCacheState()
        }
        if outcome.purgedCount > 0 {
            AppLog.shared.log(
                "purgeOldTrashedItemsIfEnabled: permanently deleted \(outcome.purgedCount) items (older than \(days) days)",
                level: .info
            )
        }
    }

    /// Pure target selection for the scheduler's auto-clean step.
    ///
    /// **Risky gate (#1)** — drops any row whose `effectiveRisk` is `.risky`.
    /// This is the AI verdict whenever an evaluation exists; otherwise the
    /// hand-curated `risk` field. The user-facing toggle stays in place
    /// (they can still per-row Clean now from the popover ⋯ menu); we just
    /// refuse to *automatically* trash data flagged risky.
    ///
    /// **Smallest-subset (#2)** — sorts the eligible rows largest-first and
    /// stops as soon as the accumulated free would clear the overage. A 1 GB
    /// breach no longer trashes every auto-on row; it trashes just enough.
    /// If even all candidates don't cover the overage, returns the full set —
    /// the scheduler still cleans what it can and logs that the cap is still
    /// exceeded for the user to handle manually.
    nonisolated static func chooseAutoCleanTargets(
        from rows: [CachePathRow],
        byteOverage: Int
    ) -> [URL] {
        guard byteOverage > 0 else { return [] }
        let candidates = rows
            .filter {
                $0.exists &&
                $0.isCleanable &&
                $0.autoCleanEnabled &&
                $0.sizeBytes > 0 &&
                $0.effectiveRisk != .risky
            }
            .sorted { $0.sizeBytes > $1.sizeBytes }
        var freed = 0
        var picked: [URL] = []
        for row in candidates {
            picked.append(row.path)
            freed += row.sizeBytes
            if freed >= byteOverage { break }
        }
        return picked
    }

    /// Partition clean targets into system-cache identifiers (routed to the
    /// privileged helper) and ordinary URLs (routed to `CacheCleaner`).
    nonisolated static func splitCleanTargets(
        _ targets: [URL]
    ) -> (system: [String], normal: [URL]) {
        var system: [String] = []
        var normal: [URL] = []
        for url in targets {
            if let identifier = SystemCacheCatalog.identifier(for: url) {
                system.append(identifier)
            } else {
                normal.append(url)
            }
        }
        return (system, normal)
    }

    /// How an Add-folder selection should be handled. Pure, so the
    /// security-relevant branch (in-home vs out-of-home vs the known catalog
    /// path) is unit-tested without a view model or a file panel.
    enum AddPathKind: Equatable {
        /// Inside `$HOME` → a normal custom row, cleanable via `CacheCleaner`.
        case custom
        /// Outside `$HOME` → a user-added system row, tracking-only.
        case systemTracking
        /// Exactly a `SystemCacheCatalog` path → restore the catalog row
        /// instead of creating a tracking-only duplicate.
        case catalogRestore(path: String)
        /// Outside `$HOME` and not a cache-like location → not trackable.
        /// `reason` is shown to the user. Stops a pick like `/` or `/Users`
        /// from being persisted and recursively scanned every interval.
        case unsupported(reason: String)
    }

    /// Whether an outside-home path looks like a cache directory we're willing
    /// to track for size. Conservative allowlist: a `Caches` path component
    /// (covers `/Library/Caches/...`, `/System/Library/Caches/...`), or the
    /// per-user temp/cache area under `/private/var/folders`. Everything else
    /// (`/`, `/Users`, `/Library` root, `/Applications`, external mounts) is
    /// rejected so a scan can't be pointed at an arbitrary huge tree.
    nonisolated static func isCacheLikeSystemPath(_ url: URL) -> Bool {
        let std = url.standardizedFileURL
        if std.pathComponents.contains(where: {
            $0.caseInsensitiveCompare("Caches") == .orderedSame
        }) {
            return true
        }
        return std.path == "/private/var/folders"
            || std.path.hasPrefix("/private/var/folders/")
    }

    /// Classify a folder the user chose in the Add panel. Standardizes first so
    /// symlinked picker results (e.g. `/private/var/...`) compare correctly.
    nonisolated static func classifyAddPath(_ url: URL, home: URL) -> AddPathKind {
        let std = url.standardizedFileURL
        if SystemCacheCatalog.identifier(for: std) != nil {
            return .catalogRestore(path: std.path)
        }
        // Match the home dir itself or a true descendant — the trailing
        // separator stops a sibling like `/Users/aliceEvil` from passing the
        // prefix test against `/Users/alice` and being treated as in-home.
        let homePath = home.standardizedFileURL.path
        if std.path == homePath || std.path.hasPrefix(homePath + "/") {
            return .custom
        }
        guard isCacheLikeSystemPath(std) else {
            return .unsupported(reason: "Only cache folders can be tracked outside your home directory. Choose a folder under a “Caches” directory.")
        }
        return .systemTracking
    }

    /// The default + catalog-system rows, minus any whose path is tombstoned.
    /// Single source of truth for the hydration re-seed.
    nonisolated static func seedRows(removingTombstoned removed: Set<String>) -> [CachePathRow] {
        CacheStubData.defaultRows().filter { !removed.contains($0.path.path) }
    }

    /// The seeded built-in rows the user has removed — drives the Add menu's
    /// "restore" section. Returns the original seed definitions (full metadata).
    nonisolated static func hiddenBuiltInRows(removed: Set<String>) -> [CachePathRow] {
        CacheStubData.defaultRows().filter { removed.contains($0.path.path) }
    }

    /// Patch system-cache rows with sizes measured by the root helper, keyed
    /// by `SystemCacheCatalog` identifier. Pure so it is unit-tested without a
    /// live view model. Non-system rows are left untouched.
    /// Apply unprivileged `CacheCleaner` scan entries to their matching rows —
    /// but **never** to catalog system caches. The unprivileged walk can't read
    /// those root-only paths and reports them as 0 bytes; letting that 0 reach a
    /// catalog row drops it below the popover's `sizeBytes > 0` filter until the
    /// privileged size query restores it, producing a visible disappear/reappear
    /// flicker on every scan. Catalog rows are sized exclusively by
    /// `applyingSystemSizes` from the privileged helper.
    ///
    /// The skip is keyed on catalog membership, not on `isSystem`: user-added
    /// system-scope folders (`isSystem && isCustom`, no catalog identifier) are
    /// never touched by the privileged helper, so the unprivileged walk is their
    /// only size source and must still be applied.
    nonisolated static func applyingScanEntries(
        _ rows: [CachePathRow], entries: [CacheReport.Entry]
    ) -> [CachePathRow] {
        var rows = rows
        for entry in entries {
            guard let idx = rows.firstIndex(where: { $0.path == entry.path }) else { continue }
            // Privileged helper owns catalog-cache sizes; skip only those.
            if SystemCacheCatalog.identifier(for: rows[idx].path) != nil { continue }
            rows[idx].sizeBytes = entry.bytes
            rows[idx].exists = entry.exists
        }
        return rows
    }

    nonisolated static func applyingSystemSizes(
        _ rows: [CachePathRow], sizes: [String: Int64]
    ) -> [CachePathRow] {
        var rows = rows
        for (identifier, bytes) in sizes {
            guard let entry = SystemCacheCatalog.entry(for: identifier) else { continue }
            if let idx = rows.firstIndex(where: {
                $0.path.standardizedFileURL.path == entry.path
            }) {
                rows[idx].sizeBytes = Int(bytes)
                rows[idx].exists = true
            }
        }
        return rows
    }

    /// Rows the bulk AI evaluator should ask about: those with no evaluation
    /// yet, excluding system caches. System caches are known-safe Apple
    /// caches (see `SystemCacheCatalog`) — spending an LLM call on them is
    /// waste, and they render a fixed descriptor instead of an AI verdict.
    /// Every row, regardless of whether it already carries an evaluation or
    /// is a system cache. "Evaluate all" has force-overwrite semantics to
    /// match the per-row refresh (`cacheReEvaluateRow`): pressing it always
    /// re-runs the whole list. Filtering out already-evaluated rows turned
    /// batch into a permanent no-op once the user had evaluated everything
    /// once. System rows are included too — the model judges a cache from its
    /// path (it never reads the folder), so a system path like the Icon
    /// services cache is just as evaluable as a user cache.
    nonisolated static func bulkEvaluationCandidates(
        from rows: [CachePathRow]
    ) -> [CachePathRow] {
        rows
    }

    /// A finished cache-AI evaluation worth surfacing as a notification when
    /// the popover closed before it completed.
    enum CacheEvalNotification {
        /// Bulk run finished; `count` is how many rows were evaluated.
        case bulkSuccess(count: Int)
        case bulkFailure
        /// Single-row run finished. `rowID` keys the identifier so concurrent
        /// per-row evals don't collapse into one banner; `name` is the row's
        /// display name.
        case rowSuccess(rowID: UUID, name: String)
        case rowFailure(rowID: UUID, name: String)
    }

    /// Notification copy + a stable identifier for a finished cache-AI
    /// evaluation. Pure so the strings, pluralization, and identifier scheme
    /// are unit-testable without spawning the view model. Bulk shares one
    /// identifier (a re-run replaces the prior banner); per-row identifiers
    /// are keyed by row so several can coexist.
    nonisolated static func cacheEvalNotificationContent(
        _ kind: CacheEvalNotification
    ) -> (identifier: String, title: String, body: String) {
        switch kind {
        case .bulkSuccess(let count):
            let noun = count == 1 ? "cache" : "caches"
            return ("kwota.cache.eval.bulk",
                    "Cache evaluation complete",
                    "Analyzed \(count) \(noun).")
        case .bulkFailure:
            return ("kwota.cache.eval.bulk",
                    "Cache evaluation failed",
                    "Couldn't finish — open Kwota to retry.")
        case .rowSuccess(let rowID, let name):
            return ("kwota.cache.eval.row.\(rowID.uuidString)",
                    "Cache evaluation complete",
                    "Evaluated '\(name)'.")
        case .rowFailure(let rowID, let name):
            return ("kwota.cache.eval.row.\(rowID.uuidString)",
                    "Cache evaluation failed",
                    "Couldn't evaluate '\(name)' — open Kwota to retry.")
        }
    }

    /// Post a cache-eval completion notification, but only while the popover
    /// is closed — if it's open the user can already see the result inline,
    /// so a banner would be redundant.
    private func notifyCacheEvalIfBackgrounded(_ kind: CacheEvalNotification) {
        guard !isPopoverOpen else { return }
        let content = Self.cacheEvalNotificationContent(kind)
        Task {
            await notificationDispatcher.post(
                identifier: content.identifier,
                title: content.title,
                body: content.body
            )
        }
    }

    /// Per-path auto-clean map for persistence. Uses a last-wins merge so a
    /// duplicate `path.path` across rows can't trap `Dictionary.init` the way
    /// `uniqueKeysWithValues` would. Pure + nonisolated so it's unit-testable.
    nonisolated static func autoCleanMap(from rows: [CachePathRow]) -> [String: Bool] {
        Dictionary(rows.map { ($0.path.path, $0.autoCleanEnabled) },
                   uniquingKeysWith: { _, last in last })
    }

    /// Bulk clean: remove the immediate contents of every selected target,
    /// then force a full rescan so every row reflects its new (typically
    /// empty) size. Drives the global `isCleaning`/`isScanning` flags — the
    /// footer legitimately reflects a multi-folder operation. Per-row clean
    /// (`cacheCleanRow`) deliberately does NOT come through here: it stays
    /// off the global flags so a single delete doesn't churn the footer.
    /// Used by `cacheCleanNow` and the auto-clean scheduler.
    func cacheClean(targets: [URL], surfaceErrors: Bool) async {
        guard !cacheState.isCleaning, !cacheState.isScanning,
              cacheState.cleaningRowIDs.isEmpty else { return }
        guard !targets.isEmpty else { return }

        cacheState.isCleaning = true
        await performClean(targets: targets, surfaceErrors: surfaceErrors)
        cacheState.isCleaning = false

        // Refresh so the popover stops showing pre-clean sizes. Force-true
        // because we just invalidated the data ourselves — the interval
        // gate doesn't apply.
        await cacheScan(force: true)
    }

    /// Remove the immediate contents of `targets`. Ordinary URLs go through
    /// `CacheCleaner` (Trash, or hard delete when `deletePermanently` is
    /// on). System-cache URLs go through the privileged helper, which always
    /// hard-deletes. `surfaceErrors` is true for user-initiated cleans
    /// (failures show an inline alert) and false for background auto-clean
    /// (failures are logged only). Shared by `cacheClean` and
    /// `cacheCleanRow`; the caller owns its in-flight flag and rescan.
    ///
    /// Error banners are cleared on SUCCESS, per category, never speculatively:
    /// a successful clean of a category clears that category's banner (even a
    /// background auto-clean that genuinely resolves it); a failure leaves the
    /// other category's banner untouched, and a background failure stays
    /// silent. This avoids erasing a still-valid signal — see the regression
    /// tests in MenuBarViewModelCacheCleanErrorTests.
    private func performClean(targets: [URL], surfaceErrors: Bool) async {
        let permanent = cacheState.settings.deletePermanently
        let split = Self.splitCleanTargets(targets)

        var totalBytesFreed = 0
        var totalItems = 0

        if !split.normal.isEmpty {
            let normal = split.normal
            let report = await OffMain.run {
                CacheCleaner(targets: normal, deletePermanently: permanent).clean()
            }
            totalBytesFreed += report.totalBytesFreed
            totalItems += report.totalItemsMoved

            // Track every URL we put in Trash so the optional auto-empty
            // sweep can permanent-delete only Kwota's own items later. In
            // permanent-delete mode `trashedItemURLs` is empty (no-op).
            let now = Date()
            for entry in report.entries {
                for url in entry.trashedItemURLs {
                    cacheState.trashedItems.append(.init(
                        originalPath: entry.path.path,
                        trashedURLPath: url.path,
                        trashedAt: now
                    ))
                }
            }

            let firstErrorEntry = report.entries.first { $0.firstError != nil }
            if let entry = firstErrorEntry, let err = entry.firstError {
                // Surface a failure only for user-initiated cleans; background
                // auto-clean stays silent. Either way, do NOT clear the banner.
                if surfaceErrors {
                    cacheState.normalCleanError = "Could not clean \(entry.path.lastPathComponent): \(err)"
                }
            } else {
                // Normal clean succeeded — clear any stale banner for this
                // category (and only this category).
                cacheState.normalCleanError = nil
            }
        }

        if !split.system.isEmpty {
            let systemOutcome = await runSystemClean(
                identifiers: split.system, surfaceErrors: surfaceErrors)
            totalItems += systemOutcome.items
            totalBytesFreed += systemOutcome.bytes
        }

        cacheState.lastCleanedBytes = totalBytesFreed
        cacheState.lastCleanedAt = Date()

        let verb = permanent ? "deleted" : "trashed"
        AppLog.shared.log(
            "cache clean completed — \(totalItems) items / \(totalBytesFreed) bytes \(verb)/removed across \(targets.count) paths",
            level: .info
        )
    }

    /// Drive a system-cache clean through the privileged helper. Returns the
    /// items/bytes freed (zero on any failure). A success clears any standing
    /// `systemCleanError` banner — even from a background auto-clean, since the
    /// cache is now actually clean. When `surfaceErrors` is set, a failure
    /// populates `cacheState.systemCleanError` for the inline alert; background
    /// callers leave the banner as-is and only log, so a silent failure can't
    /// erase a signal the user still needs.
    private func runSystemClean(
        identifiers: [String], surfaceErrors: Bool
    ) async -> (items: Int, bytes: Int) {
        let result = await privilegedHelper.cleanSystemCaches(identifiers: identifiers)
        switch result {
        case .success(let outcome):
            cacheState.systemCleanError = nil
            AppLog.shared.log(
                "system cache clean — \(outcome.itemsRemoved) items / \(outcome.bytesFreed) bytes removed",
                level: .info
            )
            return (outcome.itemsRemoved, Int(outcome.bytesFreed))
        case .failure(let error):
            AppLog.shared.log("system cache clean failed: \(error)", level: .warn)
            if surfaceErrors {
                cacheState.systemCleanError = error
            }
            return (0, 0)
        }
    }

    /// Re-measure a single path and patch its row in place — without
    /// touching the global `isScanning` flag, so a per-row clean's refresh
    /// never surfaces as a footer "Scanning…" indicator.
    private func rescanRowQuietly(path: URL) async {
        // System caches are root-only — the unprivileged walk would report 0
        // bytes and drop the row from the popover. Size them through the
        // privileged helper instead (same source as the full scan), so a
        // per-row clean's refresh reflects the real post-clean size.
        if let identifier = SystemCacheCatalog.identifier(for: path) {
            let sizes = await privilegedHelper.systemCacheSizes(identifiers: [identifier])
            if !sizes.isEmpty {
                cacheState.rows = Self.applyingSystemSizes(cacheState.rows, sizes: sizes)
            }
            saveCacheState()
            return
        }
        // Off-main GCD enumeration (see `cacheScan` — a detached task awaiting
        // the implicitly-@MainActor `scanConcurrent` would hop back to main).
        let entries = await OffMain.run { CacheCleaner(targets: [path]).scan().entries }
        cacheState.rows = Self.applyingScanEntries(cacheState.rows, entries: entries)
        saveCacheState()
    }

    /// Bulk clean: every auto-on row with content. Confirms first via
    /// NSAlert because the action covers multiple folders at once and the
    /// total can be 10s of GB — easy to misclick. The alert copy reflects
    /// whether permanent-delete is on (irreversible) or the default Trash
    /// route (recoverable).
    func cacheCleanNow() {
        let targets = cacheState.rows.filter {
            $0.exists && $0.isCleanable && $0.autoCleanEnabled && $0.sizeBytes > 0
        }
        guard !targets.isEmpty else { return }

        let totalBytes = targets.reduce(0) { $0 + $1.sizeBytes }
        let count = targets.count
        let permanent = cacheState.settings.deletePermanently
        let alert = NSAlert()
        alert.messageText = permanent
            ? "Permanently delete \(count) cache folder\(count == 1 ? "" : "s")?"
            : "Clean \(count) cache folder\(count == 1 ? "" : "s")?"
        alert.informativeText = permanent
            ? "\(totalBytes.formattedBytes) will be permanently deleted and cannot be recovered."
            : "\(totalBytes.formattedBytes) will be moved to the Trash. You can recover items from Finder until the Trash is emptied."
        alert.alertStyle = .warning
        alert.addButton(withTitle: permanent ? "Delete" : "Clean")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let urls = targets.map(\.path)
        Task { await cacheClean(targets: urls, surfaceErrors: true) }
    }

    func cacheToggleAuto(rowID: UUID) {
        guard let idx = cacheState.rows.firstIndex(where: { $0.id == rowID }) else { return }
        cacheState.rows[idx].autoCleanEnabled.toggle()
        saveCacheState()
    }

    /// Append a user-supplied path. Defaults: auto-clean OFF, risk `.caution`
    /// (custom paths are unknown territory until the user trusts them).
    /// `isSystem: true` marks a user-added system-scope path (outside `$HOME`)
    /// — it becomes `isSystem && isCustom`, i.e. tracking-only (`isCleanable`
    /// is false), so no Clean affordance is shown and it never reaches the
    /// privileged helper (no catalog identifier) or `CacheCleaner`.
    func cacheAddCustomPath(url: URL, displayName: String? = nil, isSystem: Bool = false) {
        guard !cacheState.rows.contains(where: {
            $0.path.standardizedFileURL.path == url.standardizedFileURL.path
        }) else {
            AppLog.shared.log(
                "cacheAddCustomPath: \(url.path) is already tracked — ignoring duplicate",
                level: .info)
            return
        }
        let row = CachePathRow(
            displayName: displayName ?? url.lastPathComponent,
            path: url,
            sizeBytes: 0,
            risk: .caution,
            autoCleanEnabled: false,
            isCustom: true,
            isSystem: isSystem
        )
        cacheState.rows.append(row)
        saveCacheState()
    }

    /// Remove any row from tracking. Never deletes files; never mutates
    /// `SystemCacheCatalog`. Custom and user-added system rows persist
    /// positively in `customPaths`, so dropping them from the list is enough.
    /// Seeded built-ins (defaults + catalog system) are re-seeded each launch,
    /// so they're tombstoned in `removedDefaultPaths` for the hydration filter.
    /// The tombstone is keyed on the raw `path.path` so it matches `seedRows`.
    func cacheRemoveRow(rowID: UUID) {
        guard let row = cacheState.rows.first(where: { $0.id == rowID }) else { return }
        if !row.isCustom {
            cacheState.removedDefaultPaths.insert(row.path.path)
        }
        cacheState.rows.removeAll { $0.id == rowID }
        saveCacheState()
    }

    /// Restore a previously-removed built-in row by its path: clear the
    /// tombstone and re-append the seed definition (full original metadata) if
    /// it isn't already present. Drives the Add menu's restore section.
    func cacheRestoreRemovedRow(path: String) {
        cacheState.removedDefaultPaths.remove(path)
        if !cacheState.rows.contains(where: { $0.path.path == path }),
           let seed = CacheStubData.defaultRows().first(where: { $0.path.path == path }) {
            cacheState.rows.append(seed)
        }
        saveCacheState()
    }

    func cacheResetDefaults() {
        cacheState.rows = CacheStubData.defaultRows()
        cacheState.settings = .stubDefault
        cacheState.aiModel = .default
        cacheState.riskyAlertedPaths.removeAll()
        cacheState.removedDefaultPaths.removeAll()
        saveCacheState()
    }

    func cacheUpdate(settings: AutoCleanSettings) {
        let previousInterval = cacheState.settings.scanInterval
        cacheState.settings = settings
        // Keep nextScanAt aligned with the new interval so the popover's
        // "Next scan in …" indicator updates immediately.
        cacheState.nextScanAt = Date().addingTimeInterval(settings.scanInterval.seconds)
        // Restart the scheduler when the interval changes so the new
        // cadence takes effect immediately. Without this the current
        // in-flight `Task.sleep` would still finish on the old interval
        // (up to 4h later) before honouring the new value.
        if settings.scanInterval != previousInterval && cacheSchedulerTask != nil {
            AppLog.shared.log(
                "scanInterval changed \(previousInterval.label) → \(settings.scanInterval.label); restarting scheduler",
                level: .info
            )
            startCacheScheduler()
        }
        saveCacheState()
    }

    /// Toggle the permanent-delete setting. Enabling it skips the Trash on
    /// every subsequent clean — irreversible — so we gate the *on*
    /// transition behind an explicit NSAlert. Turning it back off needs no
    /// confirm. Lives in the VM (not the Settings view) so the alert sits
    /// alongside the other cache-clean confirmations.
    func cacheSetDeletePermanently(_ enabled: Bool) {
        guard enabled != cacheState.settings.deletePermanently else { return }
        if enabled {
            let alert = NSAlert()
            alert.messageText = "Delete cleaned cache permanently?"
            alert.informativeText = """
            With this on, cleaning skips the Trash — freed files are deleted \
            immediately and cannot be recovered. This applies to manual \
            cleans and to auto-clean. You can turn it off again any time.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        cacheUpdate(settings: cacheState.settings.with(deletePermanently: enabled))
    }

    // MARK: - Cache (Phase 2 — per-row clean; AI actions still stub)

    /// Targeted clean for a single row. In the default Trash mode there's
    /// no confirm dialog — the user already drilled into the ⋯ menu, and
    /// Trash makes the action reversible if they hit the wrong row. When
    /// permanent-delete is on that reversibility is gone, so the row gets a
    /// one-tap confirm (matching Finder's "Delete Immediately").
    ///
    /// Deliberately stays off the global `isCleaning`/`isScanning` flags so
    /// a single-row delete doesn't churn the footer. `cleaningRowIDs` is
    /// both the row's feedback flag and the per-row mutex; it brackets the
    /// clean plus the *scoped* rescan (`rescanRowQuietly`, one path only).
    /// Rejected upfront when any clean/scan already owns the VM.
    func cacheCleanRow(rowID: UUID) {
        guard let row = cacheState.rows.first(where: { $0.id == rowID }),
              row.exists, row.isCleanable, (row.sizeBytes > 0 || row.isSystem) else { return }
        guard cacheState.cleaningRowIDs.isEmpty,
              !cacheState.isCleaning, !cacheState.isScanning else { return }

        if cacheState.settings.deletePermanently {
            let alert = NSAlert()
            alert.messageText = "Permanently delete \(row.displayName)?"
            alert.informativeText = "\(row.sizeBytes.formattedBytes) will be permanently deleted and cannot be recovered."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        cacheState.cleaningRowIDs.insert(rowID)
        Task {
            await performClean(targets: [row.path], surfaceErrors: true)
            await rescanRowQuietly(path: row.path)
            cacheState.cleaningRowIDs.remove(rowID)
        }
    }

    func cacheRevealInFinder(rowID: UUID) {
        guard let row = cacheState.rows.first(where: { $0.id == rowID }) else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([row.path])
        #endif
    }

    func cacheCopyPath(rowID: UUID) {
        guard let row = cacheState.rows.first(where: { $0.id == rowID }) else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.path.path, forType: .string)
        #endif
    }

    /// Bulk evaluation — single API round-trip for every row that doesn't
    /// yet have an `aiEvaluation`. The model returns one array of
    /// evaluations through `record_evaluations`, matched back to rows by
    /// path. Switched from per-row sequential after observing 15 rows = 15
    /// calls, which hammered rate limits and stretched wall-clock to ~75s.
    /// Now: 1 call, ~5-10s. Rows the model omitted from its response stay
    /// nil — user can re-trigger per-row to retry.
    ///
    /// Risky transitions collected here drive the once-per-path alert via
    /// `processRiskyTransitions`.
    func cacheEvaluateAllWithAI() {
        guard !cacheState.isEvaluatingAll else { return }
        cacheState.isEvaluatingAll = true
        cacheState.aiEvaluationError = nil

        Task { @MainActor in
            defer { cacheState.isEvaluatingAll = false }

            let pending = Self.bulkEvaluationCandidates(from: cacheState.rows)
            guard !pending.isEmpty else {
                AppLog.shared.log("cacheEvaluateAllWithAI: nothing to evaluate", level: .info)
                return
            }

            let evaluator = makeCacheEvaluator()
            let result = await evaluator.evaluateBulk(
                rows: pending,
                model: cacheState.aiModel,
                language: cacheState.settings.aiLanguage
            )
            switch result {
            case .success(let byURL):
                var newRiskyPaths: [URL] = []
                for (url, eval) in byURL {
                    if let idx = cacheState.rows.firstIndex(where: { $0.path == url }) {
                        cacheState.rows[idx].aiEvaluation = eval
                        if eval.safety == .risky {
                            newRiskyPaths.append(url)
                        }
                    }
                }
                let missing = pending.count - byURL.count
                if missing > 0 {
                    AppLog.shared.log(
                        "cacheEvaluateAllWithAI: model omitted \(missing) rows — user can re-trigger per-row",
                        level: .warn
                    )
                }
                AppLog.shared.log(
                    "cacheEvaluateAllWithAI: \(byURL.count) evaluations applied (1 API call)",
                    level: .info
                )
                saveCacheState()
                processRiskyTransitions(newRiskyPaths)
                notifyCacheEvalIfBackgrounded(.bulkSuccess(count: byURL.count))
            case .failure(let err):
                AppLog.shared.log("cacheEvaluateAllWithAI: bulk failed: \(err)", level: .warn)
                cacheState.aiEvaluationError = err
                notifyCacheEvalIfBackgrounded(.bulkFailure)
            }
        }
    }

    /// Per-row re-evaluation. Always overwrites the existing eval (force
    /// refresh semantics) so the user can re-ask after they've fixed the
    /// folder or just want a second opinion.
    func cacheReEvaluateRow(rowID: UUID) {
        guard cacheState.rows.contains(where: { $0.id == rowID }) else { return }
        // System rows are evaluated too: the model judges a cache from its
        // path, never by reading the folder, so a system path like the Icon
        // services cache is as evaluable as any user cache.
        guard !cacheState.evaluatingRowIDs.contains(rowID) else { return }
        cacheState.evaluatingRowIDs.insert(rowID)
        cacheState.aiEvaluationError = nil

        Task { @MainActor in
            defer { cacheState.evaluatingRowIDs.remove(rowID) }
            guard let row = cacheState.rows.first(where: { $0.id == rowID }) else { return }

            let evaluator = makeCacheEvaluator()
            let result = await evaluator.evaluate(
                row: row,
                model: cacheState.aiModel,
                language: cacheState.settings.aiLanguage
            )
            switch result {
            case .success(let eval):
                if let stillIdx = cacheState.rows.firstIndex(where: { $0.id == rowID }) {
                    cacheState.rows[stillIdx].aiEvaluation = eval
                }
                saveCacheState()
                if eval.safety == .risky {
                    processRiskyTransitions([row.path])
                }
                notifyCacheEvalIfBackgrounded(.rowSuccess(rowID: rowID, name: row.displayName))
            case .failure(let err):
                AppLog.shared.log(
                    "cacheReEvaluateRow: '\(row.displayName)' failed: \(err)",
                    level: .warn
                )
                cacheState.aiEvaluationError = err
                notifyCacheEvalIfBackgrounded(.rowFailure(rowID: rowID, name: row.displayName))
            }
        }
    }

    /// Dismiss the inline AI-evaluation error banner. View invokes this
    /// from the banner's action button — leaves all other cache state
    /// untouched so the user can keep browsing while the error clears.
    func cacheDismissAIEvaluationError() {
        cacheState.aiEvaluationError = nil
    }

    /// Dismiss the inline system-cache-clean error banner.
    func cacheDismissSystemCleanError() {
        cacheState.systemCleanError = nil
    }

    /// Dismiss the inline normal-cache-clean error banner.
    func cacheDismissNormalCleanError() {
        cacheState.normalCleanError = nil
    }

    /// Build a fresh evaluator on demand. The evaluator is cheap (one
    /// service reference) and stateless across calls, so we don't bother
    /// caching it as a stored property.
    private func makeCacheEvaluator() -> CacheEvaluator {
        CacheEvaluator(cliRunner: cliRunner)
    }

    // MARK: - Cache persistence

    /// Hydrate `cacheState` from a persisted state snapshot. Re-seeds the
    /// row list via `seedRows(removingTombstoned:)` (the defaults minus any the
    /// user removed) then merges custom paths + per-row toggles + AI
    /// evaluations + risky-alert acks on top — this way an app update that
    /// ships new default rows still picks them up, without losing the user's
    /// overrides.
    private func applyPersistedCacheState(_ state: CachePersistedState) {
        cacheState.settings = state.settings
        cacheState.aiModel = state.aiModel
        cacheState.riskyAlertedPaths = Set(state.riskyAlertedPaths.map { URL(fileURLWithPath: $0) })
        cacheState.trashedItems = state.trashedItems

        cacheState.removedDefaultPaths = Set(state.removedDefaultPaths)
        var rows = Self.seedRows(removingTombstoned: cacheState.removedDefaultPaths)
        for cp in state.customPaths {
            rows.append(CachePathRow(
                displayName: cp.displayName,
                path: URL(fileURLWithPath: cp.urlPath),
                sizeBytes: 0,
                risk: .caution,
                autoCleanEnabled: false,
                isCustom: true,
                isSystem: cp.isSystem
            ))
        }
        for i in rows.indices {
            let pathStr = rows[i].path.path
            if let on = state.autoCleanByPath[pathStr] {
                rows[i].autoCleanEnabled = on
            }
            if let eval = state.aiEvaluationsByPath[pathStr] {
                rows[i].aiEvaluation = eval
            }
            // Stale sizes from the last session — the popover renders them
            // immediately so the user sees real numbers on launch instead
            // of the "Scanning…" placeholder. The next `cacheScan` refreshes
            // these; if interval hasn't elapsed, they remain in place.
            if let bytes = state.sizesByPath[pathStr], bytes > 0 {
                rows[i].sizeBytes = bytes
            }
        }
        cacheState.rows = rows
    }

    /// Build a snapshot of every persisted field from the current
    /// `cacheState`. Called by `saveCacheState()` before each write.
    private func currentCachePersistedState() -> CachePersistedState {
        let evalsByPath: [String: CacheAIEvaluation] = Dictionary(
            cacheState.rows.compactMap { row in
                row.aiEvaluation.map { (row.path.path, $0) }
            },
            uniquingKeysWith: { _, last in last }
        )
        let customPaths: [CachePersistedState.CustomPath] = cacheState.rows
            .filter(\.isCustom)
            .map { .init(urlPath: $0.path.path, displayName: $0.displayName, isSystem: $0.isSystem) }
        let autoCleanByPath = Self.autoCleanMap(from: cacheState.rows)
        // Persist sizes for every row that has a real size (>0) — zero
        // means "not yet scanned" or "post-clean", neither of which we
        // want to lock in as the displayed value on next launch.
        let sizesByPath: [String: Int] = Dictionary(
            cacheState.rows
                .filter { $0.sizeBytes > 0 }
                .map { ($0.path.path, $0.sizeBytes) },
            uniquingKeysWith: { _, last in last }
        )
        return CachePersistedState(
            settings: cacheState.settings,
            aiModel: cacheState.aiModel,
            aiEvaluationsByPath: evalsByPath,
            customPaths: customPaths,
            autoCleanByPath: autoCleanByPath,
            riskyAlertedPaths: cacheState.riskyAlertedPaths.map(\.path),
            sizesByPath: sizesByPath,
            trashedItems: cacheState.trashedItems,
            removedDefaultPaths: Array(cacheState.removedDefaultPaths)
        )
    }

    /// Synchronous persist. Cheap (<10 KB typical), called inline after
    /// every mutation site below. If profiling ever shows this on a hot
    /// path, debounce via DispatchSourceTimer — for now simplicity wins.
    private func saveCacheState() {
        cachePersistence.save(currentCachePersistedState())
    }


    // MARK: - Risky-verdict alert pipeline

    /// Filter the new-risky list against `riskyAlertedPaths`, then surface a
    /// single NSAlert summarizing the paths the user hasn't seen flagged
    /// before. Once-per-path semantics: a path that's been alerted on stays
    /// silent on subsequent evals, even if the verdict bounces.
    ///
    /// Visible to internal callers (real eval flow + the stub demo trigger)
    /// so the alert layout can be reviewed without wiring up a live API
    /// request. Marked `@discardableResult` so the demo can ignore the
    /// "did fire" boolean.
    @discardableResult
    func processRiskyTransitions(_ paths: [URL]) -> Bool {
        let novel = paths.filter { !cacheState.riskyAlertedPaths.contains($0) }
        guard !novel.isEmpty else { return false }

        // Look up display names so the alert reads as
        // "JetBrains caches" rather than ".../Library/Caches/JetBrains".
        let displayNames: [String] = novel.map { url in
            cacheState.rows.first(where: { $0.path == url })?.displayName ?? url.lastPathComponent
        }

        #if canImport(AppKit)
        let alert = NSAlert()
        alert.messageText = novel.count == 1
            ? "1 folder flagged risky"
            : "\(novel.count) folders flagged risky"
        alert.informativeText = """
        Kwota's AI evaluation says these folders may contain user state or \
        config that auto-clean could destroy. Auto-clean is OFF for risky \
        rows by default — review each in the popover before flipping the \
        toggle on.

        \(displayNames.map { "• \($0)" }.joined(separator: "\n"))
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        #endif

        for url in novel {
            cacheState.riskyAlertedPaths.insert(url)
        }
        saveCacheState()
        AppLog.shared.log("Risky alert fired for \(novel.count) new paths", level: .info)
        return true
    }

    #if DEBUG
    /// Stub trigger so the user can review the risky alert UI without
    /// firing a real evaluation. Picks two representative paths from the
    /// default rows and pumps them through `processRiskyTransitions`. Wired
    /// to a "Preview risky alert" button in Settings → Cache → AI
    /// evaluation. Debug-only — release builds don't expose this and the
    /// matching settings row is also `#if DEBUG`-gated, so the public VM
    /// surface stays small.
    func cacheFireRiskyAlertDemo() {
        // Reset alerted set so the demo fires every press while the UI is
        // being iterated on.
        cacheState.riskyAlertedPaths.removeAll()
        // Pick the two folders most plausibly risky to demo realistic copy.
        let demoCandidates = ["pnpm store", "iOS Simulator caches"]
        let urls: [URL] = cacheState.rows
            .filter { demoCandidates.contains($0.displayName) }
            .map(\.path)
        guard !urls.isEmpty else {
            AppLog.shared.log("cacheFireRiskyAlertDemo: no demo rows in cacheState", level: .warn)
            return
        }
        processRiskyTransitions(urls)
    }
    #endif

    /// Drop every stored evaluation. Bound to "Re-evaluate all" in Settings →
    /// Cache. Does not auto-rerun — user follows up with the footer AI button.
    /// Also clears the `riskyAlertedPaths` set so a subsequent re-eval will
    /// alert the user again on rows that come back risky — otherwise the
    /// "once per path" guard would mute the new run.
    func cacheClearAIEvaluations() {
        for idx in cacheState.rows.indices {
            cacheState.rows[idx].aiEvaluation = nil
        }
        cacheState.riskyAlertedPaths.removeAll()
        saveCacheState()
    }

    func cacheSetAIModel(_ model: AIModelChoice) {
        cacheState.aiModel = model
        saveCacheState()
    }

    // MARK: - Probe (real, used by legacy DebugPanelView)

    func runProbe() {
        Task { [probe] in
            let result = (try? await probe.run()) ?? ProbeResult(version: nil, error: "probe threw")
            await MainActor.run { self.lastProbe = result }
        }
    }

    // MARK: - Display strings

    var sessionTokensDisplay: String { Self.formatTokens(sessionTokens) }
    var dailyTokensDisplay:  String { Self.formatTokens(dailyTokens) }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return "\(n / 1_000)k" }
        return "\(n)"
    }

}
