//
//  AntigravityProviderTests.swift
//

import XCTest
@testable import Kwota

@MainActor
final class AntigravityProviderTests: XCTestCase {
    private var temp: TempDirectory!
    private var keychain: KeychainCredentialStore!
    private var profileStore: ProfileStore!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
        keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let dataRoot = temp.url
        profileStore = ProfileStore(
            profilesFile: temp.file("profiles.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in dataRoot.appendingPathComponent(id.uuidString) }
        )
    }

    override func tearDown() async throws {
        try? keychain.deleteAll()
        try await super.tearDown()
    }

    private func makeProfile(email: String? = nil, name: String = "Antigravity") -> Profile {
        Profile(
            name: name,
            authMethod: .cliSync,
            providerID: .antigravity,
            organizationId: nil,
            subscriptionRenewsAt: nil,
            email: email,
            kind: .auto,
            ownershipBoundary: Date()
        )
    }

    private func makeCredential() -> Credential {
        .cliToken(accessToken: "ignored", refreshToken: "", expiresAt: .distantFuture)
    }

    private func makeProvider(
        transport: @escaping AntigravityAPIClient.Transport,
        watcher: StubAntigravityProcessWatcher,
        readOveragesEnabled: @escaping @MainActor () -> Bool? = { nil },
        readModelCredits: (@MainActor () -> AntigravityModelCredits?)? = nil
    ) -> AntigravityProvider {
        AntigravityProvider(
            apiClient: AntigravityAPIClient(transport: transport),
            watcher: watcher,
            profileStore: profileStore,
            readModelCredits: readModelCredits ?? { .overages(readOveragesEnabled()) }
        )
    }

    func testSupportedProfileDetailFieldsIsEmailAndPlan() {
        let provider = makeProvider(
            transport: { _ in throw URLError(.unknown) },
            watcher: StubAntigravityProcessWatcher()
        )
        XCTAssertEqual(provider.supportedProfileDetailFields, [.email, .plan])
    }

    func test_reauthTitle_overridesCLIWordingForTheApp() {
        let provider = makeProvider(
            transport: { _ in throw URLError(.unknown) },
            watcher: StubAntigravityProcessWatcher()
        )
        // Antigravity has no CLI, so the default "<name> CLI session expired"
        // must be overridden.
        XCTAssertEqual(provider.reauthTitle, "Antigravity isn't running")
        XCTAssertFalse(provider.reauthTitle.contains("CLI"))
    }

    // MARK: - Identity guard

    func test_fetchUsage_throwsWhenWatcherIdentityNil() async {
        let stubTransport: AntigravityAPIClient.Transport = { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let watcher = StubAntigravityProcessWatcher()  // current = nil
        let provider = makeProvider(transport: stubTransport, watcher: watcher)
        let profile = makeProfile()
        do {
            _ = try await provider.fetchUsage(credential: makeCredential(), profile: profile)
            XCTFail("expected IdentityMismatchError when watcher has no identity")
        } catch is AntigravityProvider.IdentityMismatchError {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Happy path

    func test_fetchUsage_happyPath_returnsSummary() async throws {
        let body = #"""
        {"userStatus":{
          "name":"User Name","email":"user@gmail.com",
          "planStatus":{
            "planInfo":{"planName":"Pro","monthlyPromptCredits":50000,"monthlyFlowCredits":150000},
            "availablePromptCredits":500,"availableFlowCredits":100
          }
        }}
        """#
        let stubTransport: AntigravityAPIClient.Transport = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), resp)
        }
        let watcher = StubAntigravityProcessWatcher()
        watcher.emit(AntigravityIdentity(csrfToken: "tk", port: 49838, credentialFingerprint: "fp"))
        let profile = makeProfile()
        try profileStore.add(profile)

        let provider = makeProvider(transport: stubTransport, watcher: watcher)
        let summary = try await provider.fetchUsage(
            credential: makeCredential(),
            profile: profile
        )

        XCTAssertEqual(summary.providerID, .antigravity)
        XCTAssertNotNil(summary.payload as? AntigravityUsageSnapshot)
        // primary = worst-model utilization. No models in this snapshot
        // → primary is nil. secondary = AI Credits utilization. No wallet
        // → secondary is nil. The bucket assertions for Prompt / Flow
        // credits that this test used to make were removed alongside the
        // popover/switcher rework — those values now drive nothing in the UI.
        XCTAssertNil(summary.primary)
        XCTAssertNil(summary.secondary)
    }

    // MARK: - Backfill

    func test_fetchUsage_backfillsProfileEmailAndName() async throws {
        let body = #"""
        {"userStatus":{
          "name":"Hậu Nguyễn","email":"hau@gmail.com",
          "planStatus":{"planInfo":{"planName":"Pro"}}
        }}
        """#
        let stubTransport: AntigravityAPIClient.Transport = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), resp)
        }
        let watcher = StubAntigravityProcessWatcher()
        watcher.emit(AntigravityIdentity(csrfToken: "tk", port: 49838, credentialFingerprint: "fp"))
        let profile = makeProfile()      // email: nil, name: "Antigravity"
        try profileStore.add(profile)

        let provider = makeProvider(transport: stubTransport, watcher: watcher)
        _ = try await provider.fetchUsage(
            credential: makeCredential(),
            profile: profile
        )

        let updated = profileStore.profiles.first { $0.id == profile.id }
        // Snapshot lowercases email during decode.
        XCTAssertEqual(updated?.email, "hau@gmail.com")
        XCTAssertEqual(updated?.name, "Hậu Nguyễn")
        XCTAssertEqual(updated?.subscriptionPlan, "Pro")
    }

    // MARK: - No backfill when snapshot fields nil

    func test_fetchUsage_doesNotOverwriteExistingFieldsWithNil() async throws {
        let body = #"""
        {"userStatus":{
          "planStatus":{"planInfo":{}}
        }}
        """#
        let stubTransport: AntigravityAPIClient.Transport = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), resp)
        }
        let watcher = StubAntigravityProcessWatcher()
        watcher.emit(AntigravityIdentity(csrfToken: "tk", port: 49838, credentialFingerprint: "fp"))
        let profile = makeProfile(email: "preserved@x.com", name: "Preserved")
        try profileStore.add(profile)

        let provider = makeProvider(transport: stubTransport, watcher: watcher)
        _ = try await provider.fetchUsage(
            credential: makeCredential(),
            profile: profile
        )

        let updated = profileStore.profiles.first { $0.id == profile.id }
        XCTAssertEqual(updated?.email, "preserved@x.com")
        XCTAssertEqual(updated?.name, "Preserved")
    }

    // MARK: - New bucket mapping (worst-model + AI credits)

    func test_fetchUsage_buildsPrimary_fromWorstModelUtilization() async throws {
        // Worst remainingFraction = 0.10 → utilization 90
        let body = #"""
        {"userStatus":{
          "cascadeModelConfigData":{"clientModelConfigs":[
            {"label":"GPT-5","modelOrAlias":{"model":"gpt"}},
            {"label":"Gemini Pro","modelOrAlias":{"model":"gem"},
             "quotaInfo":{"remainingFraction":0.10}},
            {"label":"Claude","modelOrAlias":{"model":"cla"},
             "quotaInfo":{"remainingFraction":0.5}}
          ]}
        }}
        """#
        let stubTransport: AntigravityAPIClient.Transport = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), resp)
        }
        let watcher = StubAntigravityProcessWatcher()
        watcher.emit(AntigravityIdentity(csrfToken: "tk", port: 49838, credentialFingerprint: "fp"))
        let profile = makeProfile()
        try profileStore.add(profile)

        let provider = makeProvider(transport: stubTransport, watcher: watcher,
                                     readOveragesEnabled: { true })
        let summary = try await provider.fetchUsage(credential: makeCredential(), profile: profile)
        XCTAssertEqual(summary.primary?.utilization ?? -1, 90, accuracy: 0.0001)
    }

    func test_fetchUsage_buildsSecondary_fromAICreditsUtilization() async throws {
        // Pro tier ceiling = 1000. Wallet = 250. util = 75.
        let body = #"""
        {"userStatus":{
          "planStatus":{"planInfo":{"planName":"Google AI Pro","monthlyPromptCredits":5000}},
          "userTier":{"name":"Google AI Pro","availableCredits":[
            {"creditType":"GOOGLE_ONE_AI","creditAmount":250}
          ]}
        }}
        """#
        let stubTransport: AntigravityAPIClient.Transport = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), resp)
        }
        let watcher = StubAntigravityProcessWatcher()
        watcher.emit(AntigravityIdentity(csrfToken: "tk", port: 49838, credentialFingerprint: "fp"))
        let profile = makeProfile()
        try profileStore.add(profile)

        let provider = makeProvider(transport: stubTransport, watcher: watcher,
                                     readOveragesEnabled: { false })
        let summary = try await provider.fetchUsage(credential: makeCredential(), profile: profile)
        XCTAssertEqual(summary.secondary?.utilization ?? -1, 75, accuracy: 0.0001)
    }

    func test_fetchUsage_attachesOveragesEnabled_fromReader() async throws {
        let body = #"""
        {"userStatus":{"planStatus":{"planInfo":{"planName":"Pro"}}}}
        """#
        let stubTransport: AntigravityAPIClient.Transport = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), resp)
        }
        let watcher = StubAntigravityProcessWatcher()
        watcher.emit(AntigravityIdentity(csrfToken: "tk", port: 49838, credentialFingerprint: "fp"))
        let profile = makeProfile()
        try profileStore.add(profile)

        let provider = makeProvider(transport: stubTransport, watcher: watcher,
                                     readOveragesEnabled: { false })
        let summary = try await provider.fetchUsage(credential: makeCredential(), profile: profile)
        let payload = summary.payload as? AntigravityUsageSnapshot
        XCTAssertEqual(payload?.overagesEnabled, false)
    }

    func test_fetchUsage_usesSQLiteCreditFallback_whenAPIWalletEmpty() async throws {
        // API returns a healthy Pro snapshot but with NO wallet entry.
        // state.vscdb carries 1000 available credits. Pro ceiling = 1000
        // → secondary utilization 0. Without the fallback the wallet is
        // nil, the AI Credits card (and its On/Off caption) never render,
        // and the secondary bucket is nil.
        let body = #"""
        {"userStatus":{
          "planStatus":{"planInfo":{"planName":"Google AI Pro","monthlyPromptCredits":5000}},
          "userTier":{"name":"Google AI Pro","availableCredits":[]}
        }}
        """#
        let stubTransport: AntigravityAPIClient.Transport = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), resp)
        }
        let watcher = StubAntigravityProcessWatcher()
        watcher.emit(AntigravityIdentity(csrfToken: "tk", port: 49838, credentialFingerprint: "fp"))
        let profile = makeProfile()
        try profileStore.add(profile)

        let provider = makeProvider(
            transport: stubTransport, watcher: watcher,
            readModelCredits: {
                AntigravityModelCredits(overagesEnabled: true, availableCredits: 1000)
            }
        )
        let summary = try await provider.fetchUsage(credential: makeCredential(), profile: profile)
        let payload = summary.payload as? AntigravityUsageSnapshot
        XCTAssertEqual(payload?.aiCreditsFallback, 1000)
        XCTAssertEqual(payload?.aiCreditsWallet, 1000)
        XCTAssertEqual(summary.secondary?.utilization ?? -1, 0, accuracy: 0.0001)
    }

    func test_fetchUsage_apiWalletWins_overSQLiteFallback() async throws {
        // Both present: live API wallet (250) is source of truth; the
        // staler SQLite balance (1000) must not override it.
        let body = #"""
        {"userStatus":{
          "planStatus":{"planInfo":{"planName":"Google AI Pro","monthlyPromptCredits":5000}},
          "userTier":{"name":"Google AI Pro","availableCredits":[
            {"creditType":"GOOGLE_ONE_AI","creditAmount":250}
          ]}
        }}
        """#
        let stubTransport: AntigravityAPIClient.Transport = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), resp)
        }
        let watcher = StubAntigravityProcessWatcher()
        watcher.emit(AntigravityIdentity(csrfToken: "tk", port: 49838, credentialFingerprint: "fp"))
        let profile = makeProfile()
        try profileStore.add(profile)

        let provider = makeProvider(
            transport: stubTransport, watcher: watcher,
            readModelCredits: {
                AntigravityModelCredits(overagesEnabled: true, availableCredits: 1000)
            }
        )
        let summary = try await provider.fetchUsage(credential: makeCredential(), profile: profile)
        let payload = summary.payload as? AntigravityUsageSnapshot
        XCTAssertEqual(payload?.aiCreditsWallet, 250)
    }

    // MARK: - Tooltip strings

    func test_switcherBarTooltips_returnsWorstModelString() {
        let stubTransport: AntigravityAPIClient.Transport = { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let provider = makeProvider(
            transport: stubTransport,
            watcher: StubAntigravityProcessWatcher(),
            readOveragesEnabled: { true }
        )
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            planInfo: .init(planName: "Google AI Pro", monthlyPromptCredits: 5000),
            models: [
                .init(label: "Gemini Pro (High)", modelId: "g", remainingFraction: 0.03, resetTime: nil),
                .init(label: "Claude",            modelId: "c", remainingFraction: 0.8,  resetTime: nil)
            ],
            availableCredits: [.init(creditType: "GOOGLE_ONE_AI", creditAmount: 423)],
            userTierName: "Google AI Pro",
            overagesEnabled: true
        )
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: snapshot
        )
        let tips = provider.switcherBarTooltips(summary: summary)
        XCTAssertEqual(tips.primary,   "Worst usable: Gemini Pro (High) · 3% remaining")
        XCTAssertEqual(tips.secondary, "AI Credits: 423/1,000 · Overages on")
    }

    // MARK: - New bar-1 tooltip cases (exhausted-aware)

    func test_switcherBarTooltips_allModelsFresh() {
        // Every model at 100% remaining → tooltip says "all" instead of
        // singling out a tied "worst".
        let stubTransport: AntigravityAPIClient.Transport = { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let provider = makeProvider(
            transport: stubTransport,
            watcher: StubAntigravityProcessWatcher(),
            readOveragesEnabled: { true }
        )
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "Opus",       modelId: "opus",  remainingFraction: 1.0, resetTime: nil),
                .init(label: "Gemini Pro", modelId: "pro",   remainingFraction: 1.0, resetTime: nil),
                .init(label: "Sonnet",     modelId: "son",   remainingFraction: 1.0, resetTime: nil)
            ]
        )
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: snapshot
        )
        XCTAssertEqual(provider.switcherBarTooltips(summary: summary).primary,
                       "All models at full quota")
    }

    func test_switcherBarTooltips_allModelsCapped_surfacesEarliestReset() {
        // Every model exhausted with varying reset times. Tooltip uses
        // the earliest reset's countdown — the next model to come back.
        let stubTransport: AntigravityAPIClient.Transport = { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let provider = makeProvider(
            transport: stubTransport,
            watcher: StubAntigravityProcessWatcher(),
            readOveragesEnabled: { true }
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "Opus",   modelId: "opus", remainingFraction: 0, resetTime: now.addingTimeInterval(7_200)),
                .init(label: "Sonnet", modelId: "son",  remainingFraction: 0, resetTime: now.addingTimeInterval(3_600)),
                .init(label: "Gemini", modelId: "g",    remainingFraction: 0, resetTime: now.addingTimeInterval(7_200))
            ]
        )
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: snapshot
        )
        let tip = provider.switcherBarTooltips(summary: summary).primary ?? ""
        XCTAssertTrue(tip.hasPrefix("All models capped · next reset in "),
                      "got \(tip)")
    }

    func test_switcherBarTooltips_oneExhaustedFallsBackToWorstUsable() {
        // Mirrors the user-reported pivot scenario: Opus exhausted, the
        // user has moved on to Gemini Pro (60% util). Tooltip points at
        // Pro — plain text, no exhausted-hint suffix (popover carries
        // the per-model breakdown).
        let stubTransport: AntigravityAPIClient.Transport = { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let provider = makeProvider(
            transport: stubTransport,
            watcher: StubAntigravityProcessWatcher(),
            readOveragesEnabled: { true }
        )
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "Opus",         modelId: "opus",  remainingFraction: 0,    resetTime: nil),
                .init(label: "Gemini Flash", modelId: "flash", remainingFraction: 0.7,  resetTime: nil),
                .init(label: "Gemini Pro",   modelId: "pro",   remainingFraction: 0.4,  resetTime: nil)
            ]
        )
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: snapshot
        )
        XCTAssertEqual(provider.switcherBarTooltips(summary: summary).primary,
                       "Worst usable: Gemini Pro · 40% remaining")
    }

    func test_switcherBarTooltips_handlesEmptyAndOffStates() {
        let stubTransport: AntigravityAPIClient.Transport = { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let provider = makeProvider(
            transport: stubTransport,
            watcher: StubAntigravityProcessWatcher(),
            readOveragesEnabled: { false }
        )
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            availableCredits: [.init(creditType: "GOOGLE_ONE_AI", creditAmount: 100)],
            userTierName: "",                    // → tier .unknown
            overagesEnabled: false
        )
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: snapshot
        )
        let tips = provider.switcherBarTooltips(summary: summary)
        XCTAssertEqual(tips.primary,   "No model rate limits reported")
        XCTAssertEqual(tips.secondary, "AI Credits: not tracked on this plan")
    }

    // MARK: - Dimming

    func test_switcherBarDimming_secondaryTrue_whenOveragesOff() {
        let stubTransport: AntigravityAPIClient.Transport = { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let provider = makeProvider(
            transport: stubTransport,
            watcher: StubAntigravityProcessWatcher(),
            readOveragesEnabled: { false }
        )
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            overagesEnabled: false
        )
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: snapshot
        )
        let dim = provider.switcherBarDimming(summary: summary)
        XCTAssertFalse(dim.primary)
        XCTAssertTrue(dim.secondary)
    }

    func test_switcherBarDimming_allFalse_whenOveragesOnOrNil() {
        let stubTransport: AntigravityAPIClient.Transport = { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let provider = makeProvider(
            transport: stubTransport,
            watcher: StubAntigravityProcessWatcher(),
            readOveragesEnabled: { true }
        )
        for state: Bool? in [Optional<Bool>.some(true), Optional<Bool>.none] {
            let snapshot = AntigravityUsageSnapshot(
                fetchedAt: .distantPast,
                overagesEnabled: state
            )
            let summary = ProviderUsageSummary(
                providerID: .antigravity, fetchedAt: .distantPast,
                primary: nil, secondary: nil, payload: snapshot
            )
            let dim = provider.switcherBarDimming(summary: summary)
            XCTAssertFalse(dim.primary,   "state=\(state as Any)")
            XCTAssertFalse(dim.secondary, "state=\(state as Any)")
        }
    }

    // MARK: - renewalEstimate / evaluateCreditCycle

    func test_renewalEstimate_observedAnchor_projectsMonthly() {
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        var profile = makeProfile()
        profile.observedCreditResetAt = ISO8601DateFormatter().date(from: "2026-04-18T00:00:00Z")
        let est = provider.renewalEstimate(
            profile: profile, summary: nil,
            now: ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!)
        XCTAssertEqual(est?.date, ISO8601DateFormatter().date(from: "2026-06-18T00:00:00Z"))
        XCTAssertEqual(est?.prefix, "Est. resets")
        XCTAssertEqual(est?.absolute, true)
    }

    func test_renewalEstimate_fallsBackToEarliestModelReset() {
        // Header estimate, pre-observation: with no observed cycle yet, fall
        // back to the soonest model reset we know.
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let reset = ISO8601DateFormatter().date(from: "2026-05-29T02:00:00Z")!
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [.init(label: "Opus", modelId: "opus", remainingFraction: 0, resetTime: reset)]
        )
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: snapshot)
        let est = provider.renewalEstimate(
            profile: makeProfile(), summary: summary, now: .distantPast)
        XCTAssertEqual(est?.date, reset)
        XCTAssertEqual(est?.prefix, "Resets")
        XCTAssertEqual(est?.absolute, false)
    }

    func test_renewalEstimate_observedAnchorWins_overModelReset() {
        // Header estimate must keep the stable credit cycle once observed —
        // a transient model cooldown in the summary must NOT replace it.
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let modelReset = ISO8601DateFormatter().date(from: "2026-05-29T04:00:00Z")!
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [.init(label: "Sonnet", modelId: "son", remainingFraction: 0.2, resetTime: modelReset)]
        )
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: snapshot)
        var profile = makeProfile()
        profile.observedCreditResetAt = ISO8601DateFormatter().date(from: "2026-04-18T00:00:00Z")
        let est = provider.renewalEstimate(
            profile: profile, summary: summary,
            now: ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!)
        XCTAssertEqual(est?.date, ISO8601DateFormatter().date(from: "2026-06-18T00:00:00Z"),
                       "observed cycle must win over the model cooldown")
        XCTAssertEqual(est?.prefix, "Est. resets")
        XCTAssertEqual(est?.absolute, true)
    }

    func test_renewalEstimate_nilWhenNoAnchorAndNoReset() {
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let snapshot = AntigravityUsageSnapshot(fetchedAt: .distantPast)
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: snapshot)
        XCTAssertNil(provider.renewalEstimate(profile: makeProfile(), summary: summary, now: Date()))
    }

    // MARK: - switcherRenewalEstimate

    func test_switcherRenewalEstimate_followsWorstModel_notEarliestReset() {
        // The screenshot bug: the row text showed the soonest model's reset,
        // contradicting the worst-model bar beside it. The switcher estimate
        // must track the worst usable model's own reset.
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let now = ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!
        let sonnetReset = now.addingTimeInterval(5 * 86_400)
        let geminiReset = now.addingTimeInterval(4 * 3_600)
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "Sonnet", modelId: "son", remainingFraction: 0.2, resetTime: sonnetReset),
                .init(label: "Gemini", modelId: "gem", remainingFraction: 0.8, resetTime: geminiReset)
            ]
        )
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: snapshot)
        let est = provider.switcherRenewalEstimate(profile: makeProfile(), summary: summary, now: now)
        XCTAssertEqual(est?.date, sonnetReset, "must follow the worst-model bar, not earliestModelReset")
        XCTAssertEqual(est?.prefix, "Resets")
    }

    func test_switcherRenewalEstimate_worstModelWinsOverObservedAnchor() {
        // The row text sits beside the worst-model bar, so its reset outranks
        // the observed credit cycle here (unlike the header estimate).
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let reset = ISO8601DateFormatter().date(from: "2026-06-03T02:00:00Z")!
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [.init(label: "Sonnet", modelId: "son", remainingFraction: 0.2, resetTime: reset)]
        )
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: snapshot)
        var profile = makeProfile()
        profile.observedCreditResetAt = ISO8601DateFormatter().date(from: "2026-04-18T00:00:00Z")
        let est = provider.switcherRenewalEstimate(
            profile: profile, summary: summary,
            now: ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!)
        XCTAssertEqual(est?.date, reset)
        XCTAssertEqual(est?.prefix, "Resets")
    }

    func test_switcherRenewalEstimate_fallsBackToCreditCycle_whenModelsFresh() {
        // No worst-model reset (all fresh) → defer to the account-level
        // estimate (observed credit cycle).
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [.init(label: "A", modelId: "a", remainingFraction: 1.0, resetTime: nil)]
        )
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: snapshot)
        var profile = makeProfile()
        profile.observedCreditResetAt = ISO8601DateFormatter().date(from: "2026-04-18T00:00:00Z")
        let est = provider.switcherRenewalEstimate(
            profile: profile, summary: summary,
            now: ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!)
        XCTAssertEqual(est?.date, ISO8601DateFormatter().date(from: "2026-06-18T00:00:00Z"))
        XCTAssertEqual(est?.prefix, "Est. resets")
        XCTAssertEqual(est?.absolute, true)
    }

    func test_switcherRenewalEstimate_partialData_neverShowsAnotherModelsReset() {
        // Partial response: the worst model (lowest remaining → the one on the
        // bar) carries quota but NO resetTime, while a healthier model has one.
        // The switcher must not borrow that other model's reset — better to
        // show nothing than re-create the bar/text contradiction.
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let now = ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!
        let geminiReset = now.addingTimeInterval(4 * 3_600)
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "Sonnet", modelId: "son", remainingFraction: 0.2, resetTime: nil),
                .init(label: "Gemini", modelId: "gem", remainingFraction: 0.8, resetTime: geminiReset)
            ]
        )
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: snapshot)
        // No observed cycle → no honest estimate to show.
        let est = provider.switcherRenewalEstimate(profile: makeProfile(), summary: summary, now: now)
        XCTAssertNil(est, "must not fall back to earliestModelReset (Gemini's)")
    }

    func test_switcherRenewalEstimate_partialData_deferToCreditCycle_notOtherModel() {
        // Same partial shape, but with an observed cycle: defer to the cycle,
        // still never to the other model's reset.
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let now = ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!
        let geminiReset = now.addingTimeInterval(4 * 3_600)
        let snapshot = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            models: [
                .init(label: "Sonnet", modelId: "son", remainingFraction: 0.2, resetTime: nil),
                .init(label: "Gemini", modelId: "gem", remainingFraction: 0.8, resetTime: geminiReset)
            ]
        )
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: snapshot)
        var profile = makeProfile()
        profile.observedCreditResetAt = ISO8601DateFormatter().date(from: "2026-04-18T00:00:00Z")
        let est = provider.switcherRenewalEstimate(profile: profile, summary: summary, now: now)
        XCTAssertEqual(est?.date, ISO8601DateFormatter().date(from: "2026-06-18T00:00:00Z"))
        XCTAssertEqual(est?.prefix, "Est. resets")
        XCTAssertNotEqual(est?.date, geminiReset)
    }

    // Build a snapshot whose tier ceiling is Pro (1000) with a real-API
    // wallet (userTier.availableCredits) of `wallet`.
    private func proSnapshot(realWallet: Int64?, fallback: Int64? = nil) -> AntigravityUsageSnapshot {
        var snap = AntigravityUsageSnapshot(
            fetchedAt: .distantPast,
            availableCredits: realWallet.map { [.init(creditType: "GOOGLE_ONE_AI", creditAmount: $0)] } ?? [],
            userTierName: "Google AI Pro"
        )
        snap.aiCreditsFallback = fallback
        return snap
    }

    private func antigravitySummary(_ snap: AntigravityUsageSnapshot) -> ProviderUsageSummary {
        ProviderUsageSummary(providerID: .antigravity, fetchedAt: .distantPast,
                             primary: nil, secondary: nil, payload: snap)
    }

    func test_evaluateCreditCycle_detectsReset_whenRealWalletJumpsBackToFull() {
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        var profile = makeProfile()
        profile.lastCreditWallet = 50      // previously heavily consumed
        profile.lastCreditCeiling = 1000
        let now = ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!
        let eval = provider.evaluateCreditCycle(
            summary: antigravitySummary(proSnapshot(realWallet: 950)),
            profile: profile, now: now)
        XCTAssertEqual(eval?.resetDetectedAt, now)
        XCTAssertEqual(eval?.lastWallet, 950)
        XCTAssertEqual(eval?.lastCeiling, 1000)
    }

    /// The SQLite fallback must NOT drive reset detection: when the API
    /// returns no wallet, evaluateCreditCycle returns nil (skip), leaving the
    /// stored reading untouched — even though aiCreditsFallback is near full.
    func test_evaluateCreditCycle_ignoresFallbackOnlyWallet() {
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        var profile = makeProfile()
        profile.lastCreditWallet = 50
        profile.lastCreditCeiling = 1000
        // No real-API wallet (availableCredits empty); fallback says 1000.
        let eval = provider.evaluateCreditCycle(
            summary: antigravitySummary(proSnapshot(realWallet: nil, fallback: 1000)),
            profile: profile, now: Date())
        XCTAssertNil(eval)
    }

    /// A ceiling change is not a reset, but the reading is still refreshed.
    func test_evaluateCreditCycle_ceilingChange_noReset_butUpdatesReading() {
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        var profile = makeProfile()
        profile.lastCreditWallet = 200
        profile.lastCreditCeiling = 5000   // different ceiling than current (Pro=1000)
        let eval = provider.evaluateCreditCycle(
            summary: antigravitySummary(proSnapshot(realWallet: 950)),
            profile: profile, now: Date())
        XCTAssertNil(eval?.resetDetectedAt)
        XCTAssertEqual(eval?.lastWallet, 950)
        XCTAssertEqual(eval?.lastCeiling, 1000)
    }

    func test_evaluateCreditCycle_firstReading_noReset_recordsBaseline() {
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        // Fresh profile: no prior reading.
        let eval = provider.evaluateCreditCycle(
            summary: antigravitySummary(proSnapshot(realWallet: 950)),
            profile: makeProfile(), now: Date())
        XCTAssertNil(eval?.resetDetectedAt)
        XCTAssertEqual(eval?.lastWallet, 950)
        XCTAssertEqual(eval?.lastCeiling, 1000)
    }

    // MARK: - refreshProfileMetadata

    func test_refreshProfileMetadata_appNotRunning_throwsIdentityMismatch() async throws {
        let provider = makeProvider(
            transport: { _ in throw URLError(.unknown) },
            watcher: StubAntigravityProcessWatcher()   // current = nil → app not running
        )
        let profile = makeProfile()
        try profileStore.add(profile)
        do {
            _ = try await provider.refreshProfileMetadata(for: profile, credential: makeCredential())
            XCTFail("expected identityMismatch")
        } catch let ProviderMetadataRefreshError.identityMismatch(msg) {
            XCTAssertTrue(msg.contains("Antigravity"), "banner should name Antigravity: \(msg)")
        }
    }

    func test_refreshProfileMetadata_backfillChangesFields_returnsTrue() async throws {
        let body = #"""
        {"userStatus":{
          "name":"Hậu Nguyễn","email":"hau@gmail.com",
          "planStatus":{"planInfo":{"planName":"Pro"}}
        }}
        """#
        let watcher = StubAntigravityProcessWatcher()
        watcher.emit(AntigravityIdentity(csrfToken: "tk", port: 49838, credentialFingerprint: "fp"))
        let provider = makeProvider(
            transport: { req in
                (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            watcher: watcher
        )
        let profile = makeProfile()      // email nil, name "Antigravity"
        try profileStore.add(profile)
        let changed = try await provider.refreshProfileMetadata(for: profile, credential: makeCredential())
        XCTAssertTrue(changed)
    }

    func test_refreshProfileMetadata_noFieldChange_returnsFalse() async throws {
        let body = #"""
        {"userStatus":{
          "name":"Hậu Nguyễn","email":"hau@gmail.com",
          "planStatus":{"planInfo":{"planName":"Pro"}}
        }}
        """#
        let watcher = StubAntigravityProcessWatcher()
        watcher.emit(AntigravityIdentity(csrfToken: "tk", port: 49838, credentialFingerprint: "fp"))
        let provider = makeProvider(
            transport: { req in
                (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            watcher: watcher
        )
        // Seed the profile already carrying exactly what backfill would write.
        var profile = makeProfile(email: "hau@gmail.com", name: "Hậu Nguyễn")
        profile.subscriptionPlan = "Pro"
        try profileStore.add(profile)
        let changed = try await provider.refreshProfileMetadata(for: profile, credential: makeCredential())
        XCTAssertFalse(changed)
    }
}
