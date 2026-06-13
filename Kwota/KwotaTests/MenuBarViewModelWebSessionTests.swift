//
//  MenuBarViewModelWebSessionTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class MenuBarViewModelWebSessionTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    private func makePermissiveCoordinator(profileStore: ProfileStore) -> AutoProfileCoordinator {
        let watcher = CLIAccountWatcher(
            oauthRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        return AutoProfileCoordinator(
            watcher: watcher,
            profileStore: profileStore,
            alwaysAllowRefresh: true
        )
    }

    private func makeVM(
        orgsBody: String? = nil,
        orgsStatus: Int = 200,
        emailBody: String? = nil,
        bootstrapBody: String? = nil
    ) -> MenuBarViewModel {
        let keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let dataRoot = temp.url
        let store = ProfileStore(
            profilesFile: temp.file("profiles.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in dataRoot.appendingPathComponent(id.uuidString) }
        )
        let api = ClaudeAPIClient(transport: { req in
            if req.url?.path == "/api/organizations" {
                let resp = HTTPURLResponse(url: req.url!,
                                            statusCode: orgsStatus, httpVersion: nil, headerFields: nil)!
                return (Data((orgsBody ?? "[]").utf8), resp)
            }
            if req.url?.path == "/api/account/profile" {
                let resp = HTTPURLResponse(url: req.url!,
                                            statusCode: emailBody == nil ? 401 : 200,
                                            httpVersion: nil, headerFields: nil)!
                return (Data((emailBody ?? "").utf8), resp)
            }
            // Bootstrap plan probe: claude.ai/edge-api/bootstrap/{orgId}/app_start
            if req.url?.path.hasPrefix("/edge-api/bootstrap/") == true {
                let resp = HTTPURLResponse(url: req.url!,
                                            statusCode: bootstrapBody == nil ? 401 : 200,
                                            httpVersion: nil, headerFields: nil)!
                return (Data((bootstrapBody ?? "").utf8), resp)
            }
            let resp = HTTPURLResponse(url: req.url!,
                                        statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        })
        let usage = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: temp.file("ledger-\(UUID().uuidString).json"),
            dailyCounterURL: temp.file("daily-counter-\(UUID().uuidString).json")
        )
        let codexWatcherStub = CodexAccountWatcher(
            authRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let codexCoordStub = CodexAutoProfileCoordinator(
            watcher: codexWatcherStub,
            profileStore: store,
            keychain: keychain,
            clock: { Date() }
        )
        // Inert migrator: sandboxed defaults pre-marked complete so the live
        // startup path neither reads real UserDefaults.standard nor probes
        // the real ~/.claude.json.
        let sandboxedDefaults = UserDefaults(suiteName: "kwota-websession-test-\(UUID())")!
        sandboxedDefaults.set(true, forKey: "autoDetectMigrationCompleted")
        let inertMigrator = AutoProfileMigrator(
            profileStore: store,
            oauthRead: { nil },
            defaults: sandboxedDefaults
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
            statsStore: makeHermeticStatsStore(),
            cachePersistence: CachePersistenceStore(url: temp.file("cache-state-\(UUID().uuidString).json")),
            profileStore: store,
            credentialStore: keychain,
            apiClient: api,
            cliRefresher: stubRefresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in }),
            codexAccountWatcher: codexWatcherStub,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: makePermissiveCoordinator(profileStore: store),
            codexAutoProfileCoordinator: codexCoordStub,
            autoProfileMigrator: inertMigrator,
            activityHistorian: ActivityHistorian(autoBackfill: false)
        )
    }

    func testFindMatchingProfileMatchesByEmailCaseInsensitive() async throws {
        let vm = makeVM()
        try vm.addProfile(
            name: "Work",
            credential: .sessionKey(value: "k"),
            authMethod: .sessionKey,
            email: "Alice@Example.com"
        )
        XCTAssertEqual(
            vm.findMatchingProfile(email: "alice@example.com", orgId: nil)?.email,
            "Alice@Example.com"
        )
        XCTAssertNil(vm.findMatchingProfile(email: "bob@example.com", orgId: nil))
    }

    func testReplaceCredentialsConvertsWebProfileToCLI() async throws {
        let vm = makeVM()
        let webProfile = Profile(
            name: "Work",
            authMethod: .sessionKey,
            organizationId: "org-abc",
            email: "alice@example.com",
            sessionKeyExpiresAt: Date(timeIntervalSince1970: 1900000000)
        )
        try vm.profileStore.add(webProfile)

        let cliCred = Credential.cliToken(accessToken: "tok", refreshToken: "ref", expiresAt: Date(timeIntervalSince1970: 2000000000))
        let updated = try vm.replaceCredentials(
            profileId: webProfile.id,
            newCredential: cliCred,
            newAuthMethod: .cliSync,
            email: "alice@example.com",
            organizationId: nil
        )

        XCTAssertEqual(updated.id, webProfile.id)
        XCTAssertEqual(updated.name, "Work")
        XCTAssertEqual(updated.authMethod, .cliSync)
        XCTAssertNil(updated.sessionKeyExpiresAt, "sessionKeyExpiresAt cleared on CLI conversion")
        XCTAssertEqual(updated.organizationId, "org-abc", "Existing orgId preserved")
        XCTAssertEqual(vm.profileStore.profiles.count, 1)
        XCTAssertEqual(vm.profileStore.activeProfileId, updated.id)
    }

    // MARK: - F2: subscription plan probe (bootstrap endpoint)

    func testReplaceCredentialsOverwritesStaleSubscriptionPlan() async throws {
        // Existing CLI profile carried "Pro" from a prior keychain envelope.
        // User now signs in via web — bootstrap probe returns "Team".
        // The fresh value must overwrite the stale one (web is source of
        // truth for sessionKey conversions).
        let vm = makeVM()
        let cliProfile = Profile(
            name: "CLI",
            authMethod: .cliSync,
            organizationId: "org-abc",
            subscriptionPlan: "Pro",
            email: "alice@example.com"
        )
        try vm.profileStore.add(cliProfile)
        try vm.profileStore.setActive(id: cliProfile.id)

        let updated = try vm.replaceCredentials(
            profileId: cliProfile.id,
            newCredential: .sessionKey(value: "sk-new"),
            newAuthMethod: .sessionKey,
            email: "alice@example.com",
            organizationId: "org-abc",
            subscriptionPlan: "Team"
        )
        XCTAssertEqual(updated.subscriptionPlan, "Team",
                       "Web data overwrites stale CLI-derived plan")
    }

    func testReplaceCredentialsKeepsPlanWhenNotProvided() async throws {
        // Defensive: omitting subscriptionPlan must NOT clear an existing
        // value. Only an explicitly non-nil arg overwrites.
        let vm = makeVM()
        let profile = Profile(
            name: "Existing",
            authMethod: .sessionKey,
            subscriptionPlan: "Max",
            email: "x@example.com"
        )
        try vm.profileStore.add(profile)
        try vm.profileStore.setActive(id: profile.id)

        let updated = try vm.replaceCredentials(
            profileId: profile.id,
            newCredential: .sessionKey(value: "sk-new"),
            newAuthMethod: .sessionKey
            // subscriptionPlan omitted — must remain "Max"
        )
        XCTAssertEqual(updated.subscriptionPlan, "Max")
    }

    // MARK: - Pure parser tests for ClaudeAPIClient.extractSubscriptionInfo

    func testExtractSubscriptionInfoReturnsPlanAndCreatedAtForBilledTeam() {
        // Real fixture trimmed from a live response: nonprofit Team account
        // with active stripe subscription. Both plan and createdAt populate.
        let json = #"""
        {"account":{"memberships":[
            {"seat_tier":null,"organization":{"uuid":"other-org","raven_type":null,"billing_type":null,"created_at":null}},
            {"seat_tier":"team_bendep_nonprofit_premium","organization":{"uuid":"target-org","raven_type":"team","billing_type":"stripe_subscription","created_at":"2026-04-21T05:46:15.712628Z"}}
        ]}}
        """#.data(using: .utf8)!
        let info = ClaudeAPIClient.extractSubscriptionInfo(from: json, orgId: "target-org")
        XCTAssertEqual(info.plan, "Team")
        XCTAssertNotNil(info.createdAt)
        // 2026-04-21T05:46:15.712628Z — assert components rather than the
        // raw timestamp so the test stays stable across timezone/leap-year
        // bugs in hand-computed expectations.
        let comps = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: info.createdAt!
        )
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 4)
        XCTAssertEqual(comps.day, 21)
        XCTAssertEqual(comps.hour, 5)
        XCTAssertEqual(comps.minute, 46)
    }

    func testExtractSubscriptionInfoSkipsCreatedAtWhenBillingTypeNull() {
        // Risk 1 mitigation: org without active billing → no createdAt, so
        // ProfileCard's renewal text auto-hides instead of showing a fake date.
        let json = #"""
        {"account":{"memberships":[
            {"seat_tier":"pro","organization":{"uuid":"target-org","raven_type":null,"billing_type":null,"created_at":"2026-04-21T05:46:15.712628Z"}}
        ]}}
        """#.data(using: .utf8)!
        let info = ClaudeAPIClient.extractSubscriptionInfo(from: json, orgId: "target-org")
        XCTAssertEqual(info.plan, "Pro")
        XCTAssertNil(info.createdAt, "billing_type=null must zero out createdAt")
    }

    func testExtractSubscriptionInfoSkipsCreatedAtForFreeSeat() {
        // Risk 1 mitigation: even if billing_type is somehow set on a Free
        // seat (unlikely combination from Anthropic), don't show renewal —
        // Free has no recurring billing cycle to render.
        let json = #"""
        {"account":{"memberships":[
            {"seat_tier":"free","organization":{"uuid":"target-org","raven_type":null,"billing_type":"stripe_subscription","created_at":"2026-04-21T05:46:15.712628Z"}}
        ]}}
        """#.data(using: .utf8)!
        let info = ClaudeAPIClient.extractSubscriptionInfo(from: json, orgId: "target-org")
        XCTAssertEqual(info.plan, "Free")
        XCTAssertNil(info.createdAt, "Free seat must not surface a renewal date")
    }

    func testExtractSubscriptionInfoReturnsNilsWhenNoMembershipMatchesOrgId() {
        let json = #"""
        {"account":{"memberships":[
            {"seat_tier":"pro","organization":{"uuid":"other-org","raven_type":null,"billing_type":"stripe_subscription","created_at":"2026-04-21T05:46:15.712628Z"}}
        ]}}
        """#.data(using: .utf8)!
        let info = ClaudeAPIClient.extractSubscriptionInfo(from: json, orgId: "missing-org")
        XCTAssertNil(info.plan)
        XCTAssertNil(info.createdAt)
    }

    func testExtractSubscriptionInfoReturnsNilsForMalformedJSON() {
        for body in ["not-json", "{}"] {
            let info = ClaudeAPIClient.extractSubscriptionInfo(
                from: Data(body.utf8), orgId: "x"
            )
            XCTAssertNil(info.plan, "malformed JSON '\(body)' must not crash or fake a plan")
            XCTAssertNil(info.createdAt)
            XCTAssertNil(info.displayName)
        }
    }

    func testExtractSubscriptionInfoPrefersFullNameOverDisplayName() {
        let json = #"""
        {"account":{"full_name":"Hau Nguyen","display_name":"hau","memberships":[
            {"seat_tier":"pro","organization":{"uuid":"target-org","raven_type":null,"billing_type":"stripe_subscription","created_at":"2026-04-21T05:46:15.712628Z"}}
        ]}}
        """#.data(using: .utf8)!
        let info = ClaudeAPIClient.extractSubscriptionInfo(from: json, orgId: "target-org")
        XCTAssertEqual(info.displayName, "Hau Nguyen")
    }

    func testExtractSubscriptionInfoFallsBackToDisplayNameWhenFullNameMissing() {
        let json = #"""
        {"account":{"display_name":"hau","memberships":[
            {"seat_tier":"pro","organization":{"uuid":"target-org","raven_type":null,"billing_type":"stripe_subscription","created_at":"2026-04-21T05:46:15.712628Z"}}
        ]}}
        """#.data(using: .utf8)!
        let info = ClaudeAPIClient.extractSubscriptionInfo(from: json, orgId: "target-org")
        XCTAssertEqual(info.displayName, "hau")
    }

    func testExtractSubscriptionInfoTreatsBlankNamesAsNil() {
        // Empty/whitespace names must not pre-fill the wizard with blanks.
        let json = #"""
        {"account":{"full_name":"   ","display_name":"","memberships":[
            {"seat_tier":"pro","organization":{"uuid":"target-org","raven_type":null,"billing_type":"stripe_subscription","created_at":"2026-04-21T05:46:15.712628Z"}}
        ]}}
        """#.data(using: .utf8)!
        let info = ClaudeAPIClient.extractSubscriptionInfo(from: json, orgId: "target-org")
        XCTAssertNil(info.displayName)
    }

    // MARK: - Regression: re-auth on currently-active profile didn't refresh

    func testReplaceCredentialsRefreshesEvenWhenActiveIdUnchanged() async throws {
        // Bug repro: re-auth on the currently-active profile (e.g. CLI token
        // rotation). setActive(sameId) → @Published with removeDuplicates()
        // filters the emit → rebindHistory doesn't fire → first refresh
        // never spawns → user sees stale data until manual Reload. Fix:
        // replaceCredentials explicitly calls refreshUsageNow at the end.
        //
        // Originally written against the sessionKey path (cookie header);
        // sessionKey adoption was removed, so this is the CLI-equivalent:
        // assert the rotated bearer token appears in an Authorization
        // header observed *after* replaceCredentials returns.

        let keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let dataRoot = temp.url
        let store = ProfileStore(
            profilesFile: temp.file("profiles.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in dataRoot.appendingPathComponent(id.uuidString) }
        )
        actor Counter {
            var seen: [String] = []
            func record(_ s: String) { seen.append(s) }
            func snapshot() -> [String] { seen }
        }
        let counter = Counter()
        let api = ClaudeAPIClient(transport: { req in
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            await counter.record(auth)
            let url = req.url ?? URL(string: "https://api.anthropic.com/v1/messages")!
            let resp = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "anthropic-ratelimit-unified-5h-utilization": "0.4",
                    "anthropic-ratelimit-unified-7d-utilization": "0.2"
                ]
            )!
            return (Data(), resp)
        })

        // CLI keychain probe is required because MenuBarViewModel always
        // wires a CLITokenRefresher; without one, freshen() can short-circuit
        // unpredictably. Far-future expiry keeps freshen() a cheap no-op so
        // the bearer header reflects whatever's in the credential store.
        let kcJSON = #"""
        {"accessToken":"OLD-TOKEN","refreshToken":"r","expiresAt":"2099-01-01T00:00:00Z"}
        """#
        let refresher = CLITokenRefresher(
            reader: CLICredentialReader(
                credentialsFile: temp.file("missing.json"),
                keychainProbe: { Data(kcJSON.utf8) }
            ),
            store: keychain
        )

        let codexWatcherStub2 = CodexAccountWatcher(
            authRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let codexCoordStub2 = CodexAutoProfileCoordinator(
            watcher: codexWatcherStub2,
            profileStore: store,
            keychain: keychain,
            clock: { Date() }
        )
        let sandboxedDefaults2 = UserDefaults(suiteName: "kwota-websession-test-\(UUID())")!
        sandboxedDefaults2.set(true, forKey: "autoDetectMigrationCompleted")
        let inertMigrator2 = AutoProfileMigrator(
            profileStore: store,
            oauthRead: { nil },
            defaults: sandboxedDefaults2
        )
        // Hermetic UsageMonitor: without it the default UsageMonitor.live()
        // walks the real ~/.claude/projects tree and writes the real
        // ledger.json / usage-monitor-daily.json during the test run.
        let usage2 = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: temp.file("ledger-\(UUID().uuidString).json"),
            dailyCounterURL: temp.file("daily-counter-\(UUID().uuidString).json")
        )
        let vm = MenuBarViewModel(
            usage: usage2,
            statsStore: makeHermeticStatsStore(),
            cachePersistence: CachePersistenceStore(url: temp.file("cache-state-\(UUID().uuidString).json")),
            profileStore: store,
            credentialStore: keychain,
            apiClient: api,
            cliRefresher: refresher,
            activitySource: CompositeActivitySource(sources: []),
            awakeSessionLog: AwakeSessionLog(autoStart: false),
            cliAccountWatcher: CLIAccountWatcher(oauthRead: { nil }, fileEvents: AsyncStream { _ in }),
            codexAccountWatcher: codexWatcherStub2,
            antigravityProcessWatcher: AntigravityProcessWatcher(detect: { nil }),
            autoProfileCoordinator: makePermissiveCoordinator(profileStore: store),
            codexAutoProfileCoordinator: codexCoordStub2,
            autoProfileMigrator: inertMigrator2,
            activityHistorian: ActivityHistorian(autoBackfill: false)
        )

        // Seed: CLI profile with the OLD token, already active.
        let profile = Profile(
            name: "Alice",
            authMethod: .cliSync,
            organizationId: "org-abc",
            email: "alice@example.com"
        )
        try keychain.write(
            .cliToken(
                accessToken: "OLD-TOKEN",
                refreshToken: "r",
                expiresAt: Date().addingTimeInterval(3600)
            ),
            for: profile.id
        )
        try vm.profileStore.add(profile)
        try vm.profileStore.setActive(id: profile.id)

        // Wait for any init-driven refresh to settle, then snapshot count.
        try await Task.sleep(nanoseconds: 300_000_000)
        let beforeReplace = await counter.snapshot().count

        // Re-auth on the same profile — CLI token rotated. Without the fix,
        // no refresh fires because setActive(sameId) is filtered.
        _ = try vm.replaceCredentials(
            profileId: profile.id,
            newCredential: .cliToken(
                accessToken: "NEW-TOKEN",
                refreshToken: "r",
                expiresAt: Date().addingTimeInterval(3600)
            ),
            newAuthMethod: .cliSync,
            organizationId: "org-abc"
        )
        // Poll for the new-token request rather than sleeping a fixed
        // window — under full-suite parallel load the spawned refresh
        // Task can take longer than a 400ms fixed sleep to reach the
        // transport closure. Loop short-circuits the moment NEW-TOKEN
        // is observed, so this doesn't slow the serial-run case.
        let deadline = Date().addingTimeInterval(5.0)
        var newTokenSeen = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            let snap = await counter.snapshot()
            newTokenSeen = snap.dropFirst(beforeReplace).filter { $0.contains("NEW-TOKEN") }.count
            if newTokenSeen >= 1 { break }
        }
        XCTAssertGreaterThanOrEqual(
            newTokenSeen, 1,
            "replaceCredentials must trigger a refresh; saw no Authorization header carrying NEW-TOKEN"
        )
    }

    // MARK: - subscriptionCreatedAt parity (sessionKey vs CLI)

    func testReplaceCredentialsOverwritesStaleSubscriptionCreatedAt() async throws {
        // Same overwrite policy as plan: fresh bootstrap probe is more
        // authoritative than whatever CLI keychain or prior sessionKey-add captured.
        let vm = makeVM()
        let stale = Date(timeIntervalSince1970: 1700000000)
        let fresh = Date(timeIntervalSince1970: 1808977575)
        let profile = Profile(
            name: "Alice",
            authMethod: .cliSync,
            organizationId: "org-abc",
            subscriptionCreatedAt: stale,
            email: "x@example.com"
        )
        try vm.profileStore.add(profile)
        try vm.profileStore.setActive(id: profile.id)

        let updated = try vm.replaceCredentials(
            profileId: profile.id,
            newCredential: .sessionKey(value: "sk"),
            newAuthMethod: .sessionKey,
            email: "x@example.com",
            organizationId: "org-abc",
            subscriptionCreatedAt: fresh
        )
        XCTAssertNotNil(updated.subscriptionCreatedAt)
        XCTAssertEqual(updated.subscriptionCreatedAt!.timeIntervalSince1970, fresh.timeIntervalSince1970, accuracy: 1)
    }

    func testReplaceCredentialsKeepsCreatedAtWhenNotProvided() async throws {
        // Defensive: omitting subscriptionCreatedAt must NOT clear an
        // existing value. Same policy as plan.
        let vm = makeVM()
        let original = Date(timeIntervalSince1970: 1700000000)
        let profile = Profile(
            name: "Alice",
            authMethod: .sessionKey,
            subscriptionCreatedAt: original,
            email: "x@example.com"
        )
        try vm.profileStore.add(profile)
        try vm.profileStore.setActive(id: profile.id)

        let updated = try vm.replaceCredentials(
            profileId: profile.id,
            newCredential: .sessionKey(value: "new"),
            newAuthMethod: .sessionKey
            // subscriptionCreatedAt omitted — must remain `original`
        )
        XCTAssertNotNil(updated.subscriptionCreatedAt)
        XCTAssertEqual(updated.subscriptionCreatedAt!.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 1)
    }

    func testPlanLabelMappingTable() {
        // Locked-down mapping for the seat_tier prefixes Anthropic ships
        // today. Expanding this table requires bumping `planLabel` too.
        XCTAssertEqual(ClaudeAPIClient.planLabel(fromSeatTier: "free"), "Free")
        XCTAssertEqual(ClaudeAPIClient.planLabel(fromSeatTier: "pro"), "Pro")
        XCTAssertEqual(ClaudeAPIClient.planLabel(fromSeatTier: "pro_legacy"), "Pro")
        XCTAssertEqual(ClaudeAPIClient.planLabel(fromSeatTier: "team_bendep_nonprofit_premium"), "Team")
        XCTAssertEqual(ClaudeAPIClient.planLabel(fromSeatTier: "max_5x"), "Max")
        XCTAssertEqual(ClaudeAPIClient.planLabel(fromSeatTier: "max_20x"), "Max")
        XCTAssertEqual(ClaudeAPIClient.planLabel(fromSeatTier: "enterprise_seat_v2"), "Enterprise")
        // Unknown prefix → raw capitalized so the user sees something useful
        // instead of a silent nil.
        XCTAssertEqual(ClaudeAPIClient.planLabel(fromSeatTier: "wonderplan"), "Wonderplan")
    }
}
