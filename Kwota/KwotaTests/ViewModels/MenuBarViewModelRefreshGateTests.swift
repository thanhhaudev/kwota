//
//  MenuBarViewModelRefreshGateTests.swift
//  KwotaTests
//
//  Covers the refresh gate that stops tab-toggle and back-off-window fetches
//  from piling up usage API calls. See
//  docs/superpowers/specs/2026-05-24-refresh-gate-tab-bounce-design.md.
//

import XCTest
@testable import Kwota

@MainActor
final class MenuBarViewModelRefreshGateTests: XCTestCase {
    private var temp: TempDirectory!
    private var keychain: KeychainCredentialStore!
    private var profileStore: ProfileStore!
    private var clock: Date = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
        let service = "com.thanhhaudev.Kwota.test.\(UUID())"
        keychain = KeychainCredentialStore(service: service)
        let dataRoot = temp.url
        profileStore = ProfileStore(
            profilesFile: temp.file("profiles.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in dataRoot.appendingPathComponent(id.uuidString) }
        )
        clock = Date(timeIntervalSince1970: 1_700_000_000)
    }

    override func tearDown() async throws {
        try? keychain.deleteAll()
        try await super.tearDown()
    }

    /// Builds a hermetic API client that returns a fixed HTTP status with an
    /// empty body. Default 401 matches the "stub credential rejected" case
    /// most tests expect when an init-spawned refresh dispatches with the
    /// fake "T" token. Tests that need a 429 (with optional Retry-After)
    /// pass it explicitly.
    private func stubAPIClient(status: Int = 401, retryAfter: String? = nil) -> ClaudeAPIClient {
        ClaudeAPIClient(transport: { req in
            let url = req.url ?? URL(string: "https://example.invalid")!
            var headers: [String: String] = [:]
            if let retryAfter { headers["Retry-After"] = retryAfter }
            let resp = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
            return (Data(), resp)
        })
    }

    private func makeVM(apiClient: ClaudeAPIClient? = nil) -> MenuBarViewModel {
        // Hermetic: keep the live startup path from touching real ~/.claude,
        // and from auto-clearing the seeded profile on a "no oauth" signal.
        //
        // Two separate watcher instances are intentional:
        //  - `vmWatcher` is the VM's cliAccountWatcher; VM init calls
        //    start() on it. Its onChange is unwired, so the synchronous
        //    nil emit on start() goes nowhere.
        //  - `coordWatcher` lives inside the permissive coordinator. Coord
        //    `start()` wires onChange but never calls watcher.start(), so
        //    no emit ever reaches handle() — preserving activeProfileId.
        //
        // Migrator is short-circuited via sandboxed UserDefaults with the
        // "migration completed" flag pre-set.
        //
        // `apiClient` is injected so the init-spawned refresh never reaches
        // the real api.anthropic.com — without this the Task A from
        // rebindHistory leaks a URLSession request to the live endpoint.
        let vmWatcher = CLIAccountWatcher(
            oauthRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let coordWatcher = CLIAccountWatcher(
            oauthRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let permissiveCoord = AutoProfileCoordinator(
            watcher: coordWatcher,
            profileStore: profileStore,
            alwaysAllowRefresh: true
        )
        // Hermetic Codex stubs — prevent the live startup from reading
        // ~/.codex/auth.json and creating a phantom Codex profile.
        let codexWatcherStub = CodexAccountWatcher(
            authRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let codexCoordStub = CodexAutoProfileCoordinator(
            watcher: codexWatcherStub,
            profileStore: profileStore,
            keychain: keychain,
            clock: { Date() }
        )
        let sandboxedDefaults = UserDefaults(suiteName: "kwota-gate-test-\(UUID())")!
        sandboxedDefaults.set(true, forKey: "autoDetectMigrationCompleted")
        let inertMigrator = AutoProfileMigrator(
            profileStore: profileStore,
            oauthRead: { nil },
            defaults: sandboxedDefaults
        )
        // Hermetic UsageMonitor: prevents the live default from reading
        // ~/.claude/projects/**/*.jsonl and writing to the shared ledger
        // during parallel test runs.
        let usage = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: temp.file("ledger-\(UUID().uuidString).json"),
            dailyCounterURL: temp.file("daily-counter-\(UUID().uuidString).json")
        )
        // Stub refresher: reader points at a missing temp file with a nil
        // keychain probe so forceRefresh never touches Claude Code's real
        // Keychain item or ~/.claude/.credentials.json.
        let stubRefresher = CLITokenRefresher(
            reader: CLICredentialReader(
                credentialsFile: temp.file("missing-credentials.json"),
                keychainProbe: { nil }
            ),
            store: keychain
        )
        return MenuBarViewModel(
            usage: usage,
            cachePersistence: CachePersistenceStore(url: temp.file("cache-state-\(UUID().uuidString).json")),
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: apiClient ?? stubAPIClient(),
            cliRefresher: stubRefresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: vmWatcher,
            codexAccountWatcher: codexWatcherStub,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: permissiveCoord,
            codexAutoProfileCoordinator: codexCoordStub,
            autoProfileMigrator: inertMigrator,
            activityHistorian: ActivityHistorian(autoBackfill: false),
            now: { [unowned self] in self.clock }
        )
    }

    @discardableResult
    private func seedActiveProfile() throws -> Profile {
        let p = Profile(name: "Gate", authMethod: .cliSync, email: "g@x.com")
        try profileStore.add(p)
        try keychain.write(
            .cliToken(accessToken: "T", refreshToken: "r", expiresAt: .distantFuture),
            for: p.id
        )
        // ProfileStore.add already auto-activates the first profile; the
        // explicit setActive keeps the test robust if seedActiveProfile is
        // ever called with multiple profiles already present.
        try profileStore.setActive(id: p.id)
        return p
    }

    // MARK: - canRefreshNow

    func test_canRefreshNow_isTrue_atBaseline() {
        let vm = makeVM()
        XCTAssertTrue(vm.canRefreshNow(now: clock))
    }

    func test_canRefreshNow_isFalse_whileBackoffActive() throws {
        let p = try seedActiveProfile()
        let vm = makeVM()
        try profileStore.setActive(id: p.id)  // see test_refreshUsageNow_isBlocked_whileBackoffActive
        vm.refreshCoordinator?.applyRetryAfter(60, for: .claude)
        XCTAssertFalse(vm.canRefreshNow(now: clock))
    }

    func test_canRefreshNow_becomesTrue_afterBackoffExpires() throws {
        let p = try seedActiveProfile()
        let vm = makeVM()
        try profileStore.setActive(id: p.id)
        vm.refreshCoordinator?.applyRetryAfter(60, for: .claude)
        XCTAssertFalse(vm.canRefreshNow(now: clock))
        let later = clock.addingTimeInterval(61)
        XCTAssertTrue(vm.canRefreshNow(now: later))
    }

    func test_canRefreshNow_isFalse_whileThrottleFloorActive() {
        let vm = makeVM()
        vm.lastFetchAttemptAt = clock.addingTimeInterval(-3)
        XCTAssertFalse(vm.canRefreshNow(now: clock))
    }

    func test_canRefreshNow_becomesTrue_afterThrottleFloorExpires() {
        let vm = makeVM()
        vm.lastFetchAttemptAt = clock.addingTimeInterval(-3)
        XCTAssertFalse(vm.canRefreshNow(now: clock))
        let later = clock.addingTimeInterval(11)
        XCTAssertTrue(vm.canRefreshNow(now: later))
    }

    // MARK: - refreshUsageNow gating

    func test_refreshUsageNow_isBlocked_whenThrottleFloorActive() throws {
        try seedActiveProfile()
        let vm = makeVM()
        vm.lastFetchAttemptAt = clock.addingTimeInterval(-3) // 3s ago, floor = 10s

        let before = vm.lastFetchAttemptAt
        vm.refreshUsageNow()

        XCTAssertEqual(
            vm.lastFetchAttemptAt, before,
            "throttle should short-circuit before the attempt timestamp is rewritten"
        )
    }

    func test_refreshUsageNow_isBlocked_whileBackoffActive() throws {
        let p = try seedActiveProfile()
        let vm = makeVM()
        // VM init may auto-promote an Antigravity profile when the
        // Antigravity language_server happens to be running on the dev
        // machine (the watcher is started during `live` startup, and its
        // baseline detect is real-IO). Re-pin the active profile back to
        // the seeded Claude row so this test exercises the Claude floor
        // it advertises.
        try profileStore.setActive(id: p.id)
        vm.refreshCoordinator?.applyRetryAfter(60, for: .claude)
        vm.lastFetchAttemptAt = nil

        vm.refreshUsageNow()

        XCTAssertNil(
            vm.lastFetchAttemptAt,
            "back-off should short-circuit before the attempt timestamp is rewritten"
        )
    }

    func test_refreshUsageNow_isAllowed_whenGateOpen_andRecordsAttempt() throws {
        try seedActiveProfile()
        let vm = makeVM()
        vm.lastFetchAttemptAt = nil

        vm.refreshUsageNow()

        XCTAssertEqual(
            vm.lastFetchAttemptAt, clock,
            "an allowed call must stamp lastFetchAttemptAt to now() before spawning the Task"
        )
    }

    // MARK: - Profile switch resets throttle

    func test_profileSwitch_resetsThrottle_soNewProfileFetchesImmediately() throws {
        let a = try seedActiveProfile()
        let b = Profile(name: "B", authMethod: .cliSync, email: "b@x.com")
        try profileStore.add(b)
        try keychain.write(
            .cliToken(accessToken: "T2", refreshToken: "r2", expiresAt: .distantFuture),
            for: b.id
        )

        let vm = makeVM()

        // Simulate "profile A just fetched 3s ago"
        vm.lastFetchAttemptAt = clock.addingTimeInterval(-3)
        XCTAssertFalse(vm.canRefreshNow(now: clock),
                       "precondition: throttle should be blocking before the switch")

        // Switch to profile B
        try profileStore.setActive(id: b.id)

        XCTAssertEqual(
            vm.lastFetchAttemptAt, clock,
            "switching profile must clear the previous profile's throttle " +
            "and stamp the new profile's attempt"
        )
        XCTAssertEqual(profileStore.activeProfileId, b.id)
        _ = a // silence unused warning
    }

    // MARK: - 429 surfaces rateLimitedUntil regardless of commit gate
    //
    // Regression for codex adversarial review (2026-05-25): the 429 catch
    // block used to write `rateLimitedUntil` only inside `canCommitToUI()`.
    // A stale-generation Task hitting a 429 would push coord.backoffUntil
    // into the future but leave `rateLimitedUntil` nil, so `canRefreshNow`
    // would disable the Refresh button with no banner explaining why.
    // The fix lifts the `rateLimitedUntil` write out of the gate.

    func test_429response_setsRateLimitedUntil_soBannerSurfacesGateState() async throws {
        try seedActiveProfile()
        // Stub API returns 429 with Retry-After: 60 seconds.
        let vm = makeVM(apiClient: stubAPIClient(status: 429, retryAfter: "60"))

        // Poll up to a few seconds for the init-spawned refresh Task to
        // observe the 429 and propagate state. The fix means
        // rateLimitedUntil must be set even if a follow-up trigger has
        // already bumped refreshGeneration and rendered the commit stale.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if vm.rateLimitedUntil != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNotNil(
            vm.rateLimitedUntil,
            "429 catch must set rateLimitedUntil so the RateLimitBanner mirrors the gate state"
        )
        if let until = vm.rateLimitedUntil {
            // now() == clock in this fixture, so backoff window is clock+60.
            XCTAssertEqual(
                until.timeIntervalSince(clock), 60, accuracy: 0.001,
                "rateLimitedUntil must reflect the server's Retry-After (now() + 60s)"
            )
        }
        XCTAssertNotNil(
            vm.refreshCoordinator?.backoffUntil,
            "coordinator back-off must be set in lockstep so the gate's two read paths agree"
        )
    }

    // MARK: - 429 long Retry-After: UI cap vs coordinator verbatim
    //
    // Anthropic's /api/oauth/usage can send Retry-After in the thousands of
    // seconds (observed: ~2400s → a "retry in 40m" banner). The coordinator
    // floor honors the server verbatim so the auto cadence doesn't spam a
    // throttled endpoint, but the *UI* lockout (banner countdown + manual
    // Refresh gate) caps at manualRetryCap so the user regains agency in
    // minutes, not most of an hour.

    func test_429withLongRetryAfter_capsBannerWindow_whileCoordinatorHonorsVerbatim() async throws {
        try seedActiveProfile()
        let vm = makeVM(apiClient: stubAPIClient(status: 429, retryAfter: "2400"))

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if vm.rateLimitedUntil != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let until = try XCTUnwrap(vm.rateLimitedUntil)
        XCTAssertEqual(
            until.timeIntervalSince(clock), MenuBarViewModel.manualRetryCap, accuracy: 0.001,
            "banner window must cap at manualRetryCap even when the server asks for 2400s"
        )
        XCTAssertEqual(
            vm.refreshCoordinator?.backoffUntil(for: .claude)?.timeIntervalSince(clock),
            2400,
            "coordinator floor must keep the server's verbatim hint so auto ticks don't spam the API"
        )
    }

    func test_manualGate_opensAfterCap_whileAutomaticStaysFloored() async throws {
        try seedActiveProfile()
        let vm = makeVM(apiClient: stubAPIClient(status: 429, retryAfter: "2400"))

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if vm.rateLimitedUntil != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(vm.rateLimitedUntil, "precondition: 429 must arm the banner window")

        let afterCap = clock.addingTimeInterval(MenuBarViewModel.manualRetryCap + 1)
        XCTAssertTrue(
            vm.canRefreshNow(now: afterCap, trigger: .manual),
            "manual Refresh must unlock once the capped window elapses"
        )
        XCTAssertFalse(
            vm.canRefreshNow(now: afterCap),
            "automatic ticks must stay gated by the verbatim 2400s floor"
        )
    }

    // MARK: - Probe trigger (RateLimitBanner "Try now")
    //
    // The banner exists to offer a probe while the back-off window is open —
    // so the probe must bypass the very floor that raised the banner.
    // Before this trigger existed, "Try now" routed through the automatic
    // gate and silently no-opped for the entire countdown.

    func test_probe_bypassesBackoffFloor_andStampsAttempt() throws {
        let p = try seedActiveProfile()
        let vm = makeVM()
        try profileStore.setActive(id: p.id)
        vm.refreshCoordinator?.applyRetryAfter(2400, for: .claude)
        vm.lastFetchAttemptAt = nil

        vm.refreshUsageNow(trigger: .probe)

        XCTAssertEqual(
            vm.lastFetchAttemptAt, clock,
            "probe must fire despite the open back-off floor — that is its purpose"
        )
    }

    func test_probe_respectsBurstThrottle() throws {
        try seedActiveProfile()
        let vm = makeVM()
        vm.lastFetchAttemptAt = clock.addingTimeInterval(-3) // 3s ago, floor = 10s

        let before = vm.lastFetchAttemptAt
        vm.refreshUsageNow(trigger: .probe)

        XCTAssertEqual(
            vm.lastFetchAttemptAt, before,
            "probe keeps the 10s burst throttle — hammering Try now must not spam the API"
        )
    }

    // MARK: - Successful fetch clears rate-limit state

    func test_successfulFetch_clearsCoordinatorFloor() async throws {
        let p = try seedActiveProfile()
        let okJSON = #"""
        {"five_hour":{"utilization":10,"resets_at":"2026-06-13T00:00:00Z"},
         "seven_day":{"utilization":20,"resets_at":"2026-06-18T00:00:00Z"}}
        """#.data(using: .utf8)!
        let okClient = ClaudeAPIClient(transport: { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (okJSON, resp)
        }, now: { [unowned self] in self.clock })
        let vm = makeVM(apiClient: okClient)
        try profileStore.setActive(id: p.id)
        vm.refreshCoordinator?.applyRetryAfter(2400, for: .claude)
        vm.lastFetchAttemptAt = nil

        vm.refreshUsageNow(trigger: .probe)

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if vm.refreshCoordinator?.backoffUntil(for: .claude) == nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNil(
            vm.refreshCoordinator?.backoffUntil(for: .claude),
            "a 200 proves the throttle cleared — the stale floor must drop so auto cadence resumes"
        )
        XCTAssertNil(vm.rateLimitedUntil, "banner state clears alongside the floor")
    }

    // MARK: - rateLimitedUntil is provider-scoped across rebinds

    func test_signOut_clearsRateLimitBannerState() async throws {
        try seedActiveProfile()
        let vm = makeVM(apiClient: stubAPIClient(status: 429, retryAfter: "60"))

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if vm.rateLimitedUntil != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(vm.rateLimitedUntil, "precondition: 429 armed the banner")

        try profileStore.clearActive()

        XCTAssertNil(
            vm.rateLimitedUntil,
            "sign-out rebinds to no profile — an Anthropic banner must not survive it"
        )
    }

    // MARK: - Rebind onto a floored provider must settle, not strand
    //
    // Regression for Codex adversarial review (2026-06-12): rebindHistory
    // sets authState = .refreshing BEFORE calling refreshUsageNow. When
    // the rebound profile's provider floor is open (verbatim Retry-After
    // can be 2400s), the automatic gate blocks the fetch silently and no
    // Task ever settles authState — the tab strands on a spinner (no
    // cache) or a fake "Checking…" probing banner (with cache) until the
    // floor expires. Single-account trigger: switch away to another
    // provider and back, or sign out and back in, while throttled.

    func test_rebindOntoFlooredProvider_settlesAuthState_insteadOfStranding() throws {
        let p = try seedActiveProfile()
        let vm = makeVM()
        vm.refreshCoordinator?.applyRetryAfter(2400, for: .claude)

        // Sign out, then re-activate the same (only) Claude account while
        // the floor is still open.
        try profileStore.clearActive()
        try profileStore.setActive(id: p.id)

        XCTAssertEqual(
            vm.authState, .authenticated,
            "blocked rebind refresh must settle authState — nothing else will"
        )
        XCTAssertFalse(
            vm.isSwitchingProfile,
            "stranded isSwitchingProfile pins the whole tab on the loading placeholder"
        )
        XCTAssertNil(
            vm.lastFetchAttemptAt,
            "precondition check: the fetch really was gate-blocked (no attempt stamped)"
        )
    }

    // MARK: - Stale success must not clear a newer 429
    //
    // Regression for Codex adversarial review (2026-06-12): the Claude
    // snapshot commit uses the freshness-based canCommitSnapshot (no
    // generation check, by design), and clearRateLimitState used to ride
    // inside that block. Ordering: T1 (slow 200, gen N) still in flight
    // when T2 (fast 429, gen N+1) arms the banner + floor → T1's late
    // commit wiped the newer rate-limit state. Slow responses and 429s
    // co-occur on a degraded API, so the window is realistic.

    func test_staleSlowSuccess_doesNotClear_newer429State() async throws {
        try seedActiveProfile()

        let okJSON = #"""
        {"five_hour":{"utilization":10,"resets_at":"2026-06-13T00:00:00Z"},
         "seven_day":{"utilization":20,"resets_at":"2026-06-18T00:00:00Z"}}
        """#.data(using: .utf8)!

        // Call 1 (the init-spawned refresh = T1): parks on the gate, then
        // returns 200. Call 2+ (T2): immediate 429 with Retry-After.
        let gate = TransportGate()
        let client = ClaudeAPIClient(transport: { req in
            let call = await gate.register()
            if call == 1 {
                await gate.parkUntilReleased()
                let resp = HTTPURLResponse(
                    url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (okJSON, resp)
            }
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "2400"]
            )!
            return (Data(), resp)
        }, now: { [unowned self] in self.clock })

        let vm = makeVM(apiClient: client)

        // Wait for T1 (init refresh) to reach the transport and park.
        var deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if await gate.callCount >= 1 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let parked = await gate.callCount
        XCTAssertGreaterThanOrEqual(parked, 1, "T1 must be in flight before T2 fires")

        // T2: manual trigger past the burst throttle; gets the fast 429.
        clock = clock.addingTimeInterval(11)
        vm.refreshUsageNow(trigger: .manual)

        deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if vm.rateLimitedUntil != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(vm.rateLimitedUntil, "precondition: T2's 429 armed the banner")

        // Release T1 — its stale-generation 200 commits the snapshot
        // (freshness gate allows it) but must NOT clear T2's 429 state.
        await gate.release()
        deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if vm.snapshot != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(vm.snapshot, "T1's snapshot itself may land — only the clear is gated")

        XCTAssertNotNil(
            vm.rateLimitedUntil,
            "stale T1 success must not wipe the newer 429 banner window"
        )
        XCTAssertNotNil(
            vm.refreshCoordinator?.backoffUntil(for: .claude),
            "stale T1 success must not drop the newer verbatim floor"
        )
    }

    // MARK: - Silent-429 counter does not bleed across rebind clears
    //
    // consecutive429Count drives the 60/120/240/300 fallback ladder. It
    // must restart when the banner state is cleared on sign-out — without
    // the reset, the next provider's (or session's) FIRST silent 429
    // inherits step 2 of the ladder and backs off 120s instead of 60s.

    func test_silent429Fallback_restartsAt60s_afterSignOutCycle() async throws {
        let p = try seedActiveProfile()
        // 429 with NO Retry-After — exercises the fallback ladder.
        let vm = makeVM(apiClient: stubAPIClient(status: 429))

        var deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if vm.rateLimitedUntil != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let first = try XCTUnwrap(vm.rateLimitedUntil)
        XCTAssertEqual(
            first.timeIntervalSince(clock), 60, accuracy: 0.001,
            "first silent 429 starts the ladder at 60s"
        )

        // Sign out (clears banner state + counter), wait out the 60s
        // floor, sign back in — the rebind refresh fires and 429s again.
        try profileStore.clearActive()
        XCTAssertNil(vm.rateLimitedUntil, "sign-out clears the banner window")
        clock = clock.addingTimeInterval(61)
        try profileStore.setActive(id: p.id)

        deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if vm.rateLimitedUntil != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let second = try XCTUnwrap(vm.rateLimitedUntil)
        XCTAssertEqual(
            second.timeIntervalSince(clock), 60, accuracy: 0.001,
            "post-sign-out silent 429 must restart the ladder at 60s, not inherit step 2 (120s)"
        )
    }

    // MARK: - replaceCredentials resets throttle

    func test_replaceCredentials_resetsThrottle_soReauthFetchesImmediately() throws {
        let p = try seedActiveProfile()
        let vm = makeVM()

        vm.lastFetchAttemptAt = clock.addingTimeInterval(-3)
        XCTAssertFalse(vm.canRefreshNow(now: clock),
                       "precondition: throttle should be blocking before re-auth")

        let newCredential: Credential = .cliToken(
            accessToken: "T-new",
            refreshToken: "r-new",
            expiresAt: .distantFuture
        )
        _ = try vm.replaceCredentials(
            profileId: p.id,
            newCredential: newCredential,
            newAuthMethod: .cliSync
        )

        XCTAssertEqual(
            vm.lastFetchAttemptAt, clock,
            "re-auth must clear the throttle so the freshly-rotated credential fetches"
        )
    }

    // MARK: - rebindHistory clears `summary` (stale-data guard)
    //
    // Regression for Codex adversarial review (2026-05-25): `rebindHistory`
    // used to reset `snapshot`, `history`, and `lastFetchedAt` on profile
    // change but never cleared `self.summary`. The menu-bar icon, the
    // DisplayMenuBarCard preview, and the UsageTab fallback all read
    // `vm.summary` directly — so after sign-out or switching to a fresh
    // profile, the UI kept showing the prior provider's quota until the
    // next fetch landed. Fix: clear `summary` at the top of `rebindHistory`.

    func test_rebindHistory_signOut_clearsSummaryNotJustSnapshot() throws {
        let p = try seedActiveProfile()
        let vm = makeVM()
        // Seed a non-nil summary (simulates "we just fetched something").
        vm.summary = ProviderUsageSummary(
            providerID: .claude,
            fetchedAt: clock,
            primary: UsageBucket(utilization: 0.5, resetsAt: clock.addingTimeInterval(3600)),
            secondary: UsageBucket(utilization: 0.3, resetsAt: clock.addingTimeInterval(7 * 86400)),
            payload: UsageSnapshot.zeroes()
        )
        XCTAssertNotNil(vm.summary, "precondition: summary populated before sign-out")

        // Sign out: clear active profile.
        try profileStore.clearActive()

        XCTAssertNil(
            vm.summary,
            "rebindHistory(nil) must clear summary — menu-bar / detail consumers read it directly"
        )
        _ = p // silence unused warning
    }

    func test_rebindHistory_profileSwitch_clearsSummary() throws {
        let a = try seedActiveProfile()
        let b = Profile(name: "B", authMethod: .cliSync, email: "b@x.com")
        try profileStore.add(b)
        try keychain.write(
            .cliToken(accessToken: "T2", refreshToken: "r2", expiresAt: .distantFuture),
            for: b.id
        )

        let vm = makeVM()
        // After init's rebindHistory runs, summary may or may not be set
        // (depends on the spawn timing of the init-driven refresh task —
        // hermetic 401 stub means the task quickly sets authState=.expired
        // without committing a summary). Plant one explicitly so the
        // assertion has a definite "before" value.
        vm.summary = ProviderUsageSummary(
            providerID: .claude,
            fetchedAt: clock,
            primary: UsageBucket(utilization: 0.5, resetsAt: clock.addingTimeInterval(3600)),
            secondary: nil,
            payload: UsageSnapshot.zeroes()
        )

        // Switch to profile B — fires onActiveProfileChange → rebindHistory.
        try profileStore.setActive(id: b.id)

        XCTAssertNil(
            vm.summary,
            "profile switch must clear `summary` so the new profile's UI doesn't display the old account's quota until the next fetch lands"
        )
        XCTAssertEqual(profileStore.activeProfileId, b.id)
        _ = a
    }

    func test_rebindHistory_clearsSummary_evenWhenCachedSnapshotExists() throws {
        // Switching to a Claude profile WITH a cached snapshot still must
        // not leak the prior account's `summary` (which carries the prior
        // provider's primary/secondary buckets — distinct from
        // `Profile.lastSnapshot`).
        let a = try seedActiveProfile()
        var b = Profile(name: "B", authMethod: .cliSync, email: "b@x.com")
        b.lastSnapshot = UsageSnapshot(
            fiveHour: UsageBucket(utilization: 0.42, resetsAt: clock.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 0.1, resetsAt: clock.addingTimeInterval(7 * 86400))
        )
        try profileStore.add(b)
        try keychain.write(
            .cliToken(accessToken: "T2", refreshToken: "r2", expiresAt: .distantFuture),
            for: b.id
        )

        let vm = makeVM()
        vm.summary = ProviderUsageSummary(
            providerID: .claude,
            fetchedAt: clock,
            primary: UsageBucket(utilization: 0.99, resetsAt: clock.addingTimeInterval(3600)),
            secondary: nil,
            payload: UsageSnapshot.zeroes()
        )

        try profileStore.setActive(id: b.id)

        XCTAssertNil(
            vm.summary,
            "summary cleared regardless of whether the new profile has a cached snapshot — providerID/account boundary is what matters, not Claude-mirror availability"
        )
        _ = a
    }

    // MARK: - popoverDidOpen SWR gate

    /// Builds a ProviderUsageSummary with the given fetchedAt so tests can
    /// seed `vm.summary` and assert SWR behavior without driving the
    /// network. Payload is the standard `UsageSnapshot.zeroes()` test
    /// double — its fields are not read in this suite.
    private func summary(fetchedAt: Date) -> ProviderUsageSummary {
        ProviderUsageSummary(
            providerID: .claude,
            fetchedAt: fetchedAt,
            primary: UsageBucket(utilization: 0.1, resetsAt: nil),
            secondary: UsageBucket(utilization: 0.1, resetsAt: nil),
            payload: UsageSnapshot.zeroes()
        )
    }

    func test_popoverDidOpen_skipsRefresh_whenSummaryWithinFreshnessWindow() throws {
        try seedActiveProfile()
        let vm = makeVM()
        // Pre-seed: a successful fetch landed 5s ago. Throttle floor is
        // 10s but SWR window is 60s; the SWR gate must win and short-circuit
        // before the throttle check is even reached.
        vm.summary = summary(fetchedAt: clock.addingTimeInterval(-5))
        vm.lastFetchAttemptAt = nil  // throttle would otherwise allow

        vm.popoverDidOpen()

        XCTAssertNil(
            vm.lastFetchAttemptAt,
            "summary 5s old is well inside 60s freshnessWindow — popoverDidOpen must skip the refresh, leaving lastFetchAttemptAt untouched"
        )
    }

    func test_popoverDidOpen_refreshes_whenSummaryOutsideFreshnessWindow() throws {
        try seedActiveProfile()
        let vm = makeVM()
        // Pre-seed: a successful fetch landed 120s ago — outside the 60s
        // SWR window. popoverDidOpen must refresh.
        vm.summary = summary(fetchedAt: clock.addingTimeInterval(-120))
        vm.lastFetchAttemptAt = nil

        vm.popoverDidOpen()

        XCTAssertEqual(
            vm.lastFetchAttemptAt, clock,
            "summary 120s old is outside the SWR window — popoverDidOpen must fall through to refreshUsageNow, stamping lastFetchAttemptAt"
        )
    }

    func test_popoverDidOpen_refreshes_whenNoSummaryYet() throws {
        try seedActiveProfile()
        let vm = makeVM()
        // No prior summary (cold-start, first popover open).
        vm.summary = nil
        vm.lastFetchAttemptAt = nil

        vm.popoverDidOpen()

        XCTAssertEqual(
            vm.lastFetchAttemptAt, clock,
            "no prior summary — popoverDidOpen must refresh"
        )
    }

    func test_isPopoverOpen_tracksLifecycle() throws {
        try seedActiveProfile()
        let vm = makeVM()
        XCTAssertFalse(vm.isPopoverOpen, "popover starts closed at launch")
        vm.popoverDidOpen()
        XCTAssertTrue(vm.isPopoverOpen, "popoverDidOpen must mark it open")
        vm.popoverDidClose()
        XCTAssertFalse(vm.isPopoverOpen, "popoverDidClose must mark it closed")
    }

    // MARK: - Profile-switch SWR gate

    func test_profileSwitch_skipsRefresh_whenProfileLastFetchedAtIsFresh() throws {
        // A→B→A→B back-and-forth in the switcher used to fire a fresh
        // fetch on every switch, draining the /api/oauth/usage token
        // bucket. With the SWR gate, a switch to a profile whose
        // `lastFetchedAt` is still inside the 60s freshness window must
        // NOT fire refreshUsageNow — provided the profile also has a
        // renderable cache (Claude `lastSnapshot`) so the cleared
        // `summary` doesn't leave the chart at `.empty`.
        _ = try seedActiveProfile()
        var b = Profile(name: "B", authMethod: .cliSync, email: "b@x.com")
        b.lastFetchedAt = clock.addingTimeInterval(-5)  // 5s ago — fresh
        // Claude renderable fallback: lastSnapshot must be present for
        // the SWR skip to be visually safe.
        b.lastSnapshot = UsageSnapshot(
            fiveHour: UsageBucket(utilization: 0.3, resetsAt: clock.addingTimeInterval(3600)),
            sevenDay: UsageBucket(utilization: 0.1, resetsAt: clock.addingTimeInterval(7 * 86400))
        )
        try profileStore.add(b)
        try keychain.write(
            .cliToken(accessToken: "T2", refreshToken: "r2", expiresAt: .distantFuture),
            for: b.id
        )

        let vm = makeVM()
        // VM init can stamp lastFetchAttemptAt during bootstrap; reset to
        // a known state so the post-switch assertion is deterministic.
        vm.lastFetchAttemptAt = nil

        try profileStore.setActive(id: b.id)

        XCTAssertNil(
            vm.lastFetchAttemptAt,
            "B's lastFetchedAt 5s ago is inside the 60s SWR window — rebindHistory must skip refresh"
        )
    }

    func test_profileSwitch_codexWithoutSnapshot_refreshesEvenWhenLastFetchedAtIsFresh() throws {
        // Codex profiles never write `lastSnapshot` (that field is the
        // Claude-only legacy snapshot type). If rebindHistory clears
        // `vm.summary` and then SWR-skips the refresh based on a fresh
        // `lastFetchedAt`, the Codex profile has nothing renderable —
        // resolveUsageChartState falls through to `.empty`. The gate
        // must therefore require a renderable fallback before skipping.
        _ = try seedActiveProfile()
        var b = Profile(name: "B-codex", authMethod: .cliSync, providerID: .codex, email: "b@codex.com")
        b.lastFetchedAt = clock.addingTimeInterval(-5)  // 5s ago — fresh by SWR-window standards
        // lastSnapshot is left nil — that's the whole point of this case.
        try profileStore.add(b)
        try keychain.write(
            .cliToken(accessToken: "T2", refreshToken: "r2", expiresAt: .distantFuture),
            for: b.id
        )

        let vm = makeVM()
        vm.lastFetchAttemptAt = nil

        try profileStore.setActive(id: b.id)

        XCTAssertEqual(
            vm.lastFetchAttemptAt, clock,
            "Codex profile has no lastSnapshot fallback — SWR must NOT skip refresh even when lastFetchedAt is fresh, otherwise the chart resolves to .empty"
        )
    }

    /// Orders two concurrent transport calls deterministically: call 1
    /// parks until `release()`, later calls pass straight through. Lets a
    /// test hold a slow 200 in flight while a fast 429 completes first.
    actor TransportGate {
        private(set) var callCount = 0
        private var released = false
        private var parked: [CheckedContinuation<Void, Never>] = []

        func register() -> Int {
            callCount += 1
            return callCount
        }

        func parkUntilReleased() async {
            if released { return }
            await withCheckedContinuation { parked.append($0) }
        }

        func release() {
            released = true
            parked.forEach { $0.resume() }
            parked.removeAll()
        }
    }

    func test_profileSwitch_refreshes_whenProfileLastFetchedAtIsStale() throws {
        _ = try seedActiveProfile()
        var b = Profile(name: "B", authMethod: .cliSync, email: "b@x.com")
        b.lastFetchedAt = clock.addingTimeInterval(-120)  // 120s ago — stale
        try profileStore.add(b)
        try keychain.write(
            .cliToken(accessToken: "T2", refreshToken: "r2", expiresAt: .distantFuture),
            for: b.id
        )

        let vm = makeVM()
        vm.lastFetchAttemptAt = nil

        try profileStore.setActive(id: b.id)

        XCTAssertEqual(
            vm.lastFetchAttemptAt, clock,
            "B's lastFetchedAt 120s ago is outside the SWR window — rebindHistory must refresh"
        )
    }
}
