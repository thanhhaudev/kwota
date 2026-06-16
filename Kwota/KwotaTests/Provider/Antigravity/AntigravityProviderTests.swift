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
        readModelCredits: (@MainActor () -> AntigravityModelCredits?)? = nil,
        quotaRetryAttempts: Int = 3,
        quotaRetryDelay: TimeInterval = 0
    ) -> AntigravityProvider {
        AntigravityProvider(
            apiClient: AntigravityAPIClient(transport: transport),
            watcher: watcher,
            profileStore: profileStore,
            readModelCredits: readModelCredits ?? { .overages(readOveragesEnabled()) },
            quotaRetryAttempts: quotaRetryAttempts,
            quotaRetryDelay: quotaRetryDelay
        )
    }

    /// Transport that answers BY URL PATH: a RetrieveUserQuotaSummary request
    /// returns the quota JSON (or 503 when `quotaJSON` is nil), everything else
    /// returns the GetUserStatus snapshot JSON. `fetchUsage` now hits two RPC
    /// paths, so a single-body stub can't serve both.
    private func dualTransport(snapshotJSON: String, quotaJSON: String?) -> AntigravityAPIClient.Transport {
        { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("RetrieveUserQuotaSummary") {
                if let quotaJSON {
                    let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (Data(quotaJSON.utf8), r)
                }
                let r = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
                return (Data(), r)
            }
            let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(snapshotJSON.utf8), r)
        }
    }

    private let quotaJSON = """
    {"response":{"groups":[
      {"displayName":"Gemini Models","buckets":[
        {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":1,"resetTime":"2026-06-20T10:40:07Z"},
        {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.2,"resetTime":"2026-06-13T15:40:07Z"}]},
      {"displayName":"Claude and GPT models","buckets":[
        {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.08,"resetTime":"2026-06-20T10:40:07Z"},
        {"bucketId":"3p-5h","window":"5h","remainingFraction":1,"resetTime":"2026-06-13T15:40:07Z"}]}]}}
    """

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
        XCTAssertNotNil(summary.payload as? AntigravityUsagePayload)
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

    // MARK: - New bucket mapping (worst-group 5h + weekly from quota)

    func test_fetchUsage_buildsCompositePayloadAndWorstGroupBuckets() async throws {
        let watcher = StubAntigravityProcessWatcher()
        watcher.emit(AntigravityIdentity(csrfToken: "tk", port: 49838, credentialFingerprint: "fp"))
        let provider = makeProvider(
            transport: dualTransport(snapshotJSON: #"{"userStatus":{"email":"u@b.com"}}"#, quotaJSON: quotaJSON),
            watcher: watcher)
        let profile = makeProfile(); try profileStore.add(profile)
        let summary = try await provider.fetchUsage(credential: makeCredential(), profile: profile)
        let payload = try XCTUnwrap(summary.payload as? AntigravityUsagePayload)
        XCTAssertEqual(payload.quota?.groups.count, 2)
        XCTAssertEqual(summary.primary?.utilization ?? -1, 80, accuracy: 0.001)   // Gemini 5h worst
        XCTAssertEqual(summary.secondary?.utilization ?? -1, 92, accuracy: 0.001) // Claude+GPT weekly worst
        XCTAssertNotNil(summary.primary?.resetsAt)
        XCTAssertNotNil(summary.secondary?.resetsAt)
    }

    func test_fetchUsage_quotaMiss_degradesButKeepsIdentity() async throws {
        let watcher = StubAntigravityProcessWatcher()
        watcher.emit(AntigravityIdentity(csrfToken: "tk", port: 49838, credentialFingerprint: "fp"))
        let provider = makeProvider(
            transport: dualTransport(snapshotJSON: #"{"userStatus":{"email":"u@b.com"}}"#, quotaJSON: nil),
            watcher: watcher)
        let profile = makeProfile(); try profileStore.add(profile)
        let summary = try await provider.fetchUsage(credential: makeCredential(), profile: profile)
        let payload = try XCTUnwrap(summary.payload as? AntigravityUsagePayload)
        XCTAssertNil(payload.quota)
        XCTAssertEqual(payload.snapshot.email, "u@b.com")
        XCTAssertNil(summary.primary)
        XCTAssertEqual(profileStore.profiles.first(where: { $0.id == profile.id })?.email, "u@b.com")
    }

    func test_fetchUsage_quotaRetries_recoversFromColdStartMiss() async throws {
        // The quota endpoint 503s on the first fetch attempt (cold-start
        // backend warmup — both http+https probes inside one fetchQuotaSummary
        // call fail), then 200s. The provider must retry and end with a
        // populated quota instead of degrading to empty bars.
        let watcher = StubAntigravityProcessWatcher()
        watcher.emit(AntigravityIdentity(csrfToken: "tk", port: 49838, credentialFingerprint: "fp"))
        var quotaHits = 0
        let transport: AntigravityAPIClient.Transport = { [quotaJSON] req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("RetrieveUserQuotaSummary") {
                quotaHits += 1
                // First fetchQuotaSummary probes http then https (2 hits) —
                // fail both so attempt 1 throws; succeed from the 3rd hit.
                let status = quotaHits <= 2 ? 503 : 200
                let r = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (status == 200 ? Data(quotaJSON.utf8) : Data(), r)
            }
            let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"userStatus":{"email":"u@b.com"}}"#.utf8), r)
        }
        let provider = makeProvider(transport: transport, watcher: watcher)  // 3 attempts, 0 delay
        let profile = makeProfile(); try profileStore.add(profile)

        let summary = try await provider.fetchUsage(credential: makeCredential(), profile: profile)
        let payload = try XCTUnwrap(summary.payload as? AntigravityUsagePayload)
        XCTAssertNotNil(payload.quota, "quota recovered via retry after a cold-start miss")
        XCTAssertGreaterThanOrEqual(quotaHits, 3, "provider retried the quota sub-fetch past the first failed attempt")
        XCTAssertEqual(summary.primary?.utilization ?? -1, 80, accuracy: 0.001)
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
        let payload = (summary.payload as? AntigravityUsagePayload)?.snapshot
        XCTAssertEqual(payload?.overagesEnabled, false)
    }

    func test_fetchUsage_usesSQLiteCreditFallback_whenAPIWalletEmpty() async throws {
        // API returns a healthy Pro snapshot but with NO wallet entry.
        // state.vscdb carries 1000 available credits. Without the fallback
        // the wallet is nil and the AI Credits card (and its On/Off caption)
        // never render. The secondary switcher bucket now tracks the weekly
        // quota, not AI credits, so it's no longer asserted here.
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
        let payload = (summary.payload as? AntigravityUsagePayload)?.snapshot
        XCTAssertEqual(payload?.aiCreditsFallback, 1000)
        XCTAssertEqual(payload?.aiCreditsWallet, 1000)
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
        let payload = (summary.payload as? AntigravityUsagePayload)?.snapshot
        XCTAssertEqual(payload?.aiCreditsWallet, 250)
    }

    // MARK: - Tooltip strings (worst-group)

    /// Builds a quota-payload summary from the class `quotaJSON` fixture so the
    /// switcher hooks can be exercised without a full fetch.
    private func quotaSummary() throws -> ProviderUsageSummary {
        let quota = try AntigravityQuotaSummary.decoder.decode(
            AntigravityQuotaSummary.self, from: Data(quotaJSON.utf8))
        let payload = AntigravityUsagePayload(
            snapshot: AntigravityUsageSnapshot(fetchedAt: .distantPast), quota: quota)
        return ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: payload)
    }

    /// Builds a quota-payload summary with a single group carrying the given
    /// 5h / weekly reset times (remaining fixed at 0.5 so utilization is
    /// non-nil). Used by the renewal-estimate tests.
    private func quotaSummary(fiveHourReset: Date?, weeklyReset: Date?,
                              weeklyRemaining: Double = 0.5) -> ProviderUsageSummary {
        var buckets: [AntigravityQuotaSummary.Bucket] = []
        if let fiveHourReset {
            buckets.append(.init(bucketId: "g-5h", displayName: nil, window: .fiveHour,
                                 remainingFraction: 0.5, resetTime: fiveHourReset))
        }
        if let weeklyReset {
            buckets.append(.init(bucketId: "g-weekly", displayName: nil, window: .weekly,
                                 remainingFraction: weeklyRemaining, resetTime: weeklyReset))
        }
        let quota = AntigravityQuotaSummary(
            fetchedAt: .distantPast,
            groups: [.init(displayName: "Models", description: nil, buckets: buckets)])
        let payload = AntigravityUsagePayload(
            snapshot: AntigravityUsageSnapshot(fetchedAt: .distantPast), quota: quota)
        return ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: payload)
    }

    func test_switcherBarTooltips_namesWorstGroupPerWindow() throws {
        let provider = makeProvider(
            transport: { _ in throw URLError(.unknown) },
            watcher: StubAntigravityProcessWatcher())
        let tips = provider.switcherBarTooltips(summary: try quotaSummary())
        // Worst 5h is the Gemini group (20% remaining → 80% util); worst weekly
        // is the Claude+GPT group (8% remaining → 92% util).
        let primary = try XCTUnwrap(tips.primary)
        XCTAssertTrue(primary.hasPrefix("5-hour · "), "got \(primary)")
        XCTAssertTrue(primary.contains("Gemini"), "got \(primary)")
        XCTAssertTrue(primary.contains("20% remaining"), "got \(primary)")
        let secondary = try XCTUnwrap(tips.secondary)
        XCTAssertTrue(secondary.hasPrefix("Weekly · "), "got \(secondary)")
        XCTAssertTrue(secondary.contains("Claude"), "got \(secondary)")
    }

    func test_switcherBarTooltips_quotaNil_showsUnavailable() {
        let provider = makeProvider(
            transport: { _ in throw URLError(.unknown) },
            watcher: StubAntigravityProcessWatcher())
        let payload = AntigravityUsagePayload(
            snapshot: AntigravityUsageSnapshot(fetchedAt: .distantPast), quota: nil)
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: payload)
        let tips = provider.switcherBarTooltips(summary: summary)
        XCTAssertEqual(tips.primary, "Quota unavailable")
        XCTAssertEqual(tips.secondary, "Quota unavailable")
    }

    // MARK: - Dimming

    func test_switcherBarDimming_alwaysFalse_regardlessOfOverageState() throws {
        let provider = makeProvider(
            transport: { _ in throw URLError(.unknown) },
            watcher: StubAntigravityProcessWatcher())
        let dim = provider.switcherBarDimming(summary: try quotaSummary())
        XCTAssertFalse(dim.primary)
        XCTAssertFalse(dim.secondary)
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
        XCTAssertEqual(est?.prefix, "Est. credits reset")
        XCTAssertEqual(est?.absolute, true)
    }

    func test_renewalEstimate_fallsBackToWeeklyQuotaReset() {
        // Header estimate, pre-observation: with no observed cycle yet, prefer
        // the weekly window's reset over the 5-hour rolling window, so the card
        // shows a meaningful multi-day countdown instead of a perpetual "today".
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let fiveHour = ISO8601DateFormatter().date(from: "2026-05-29T02:00:00Z")!
        let weekly = ISO8601DateFormatter().date(from: "2026-06-02T00:00:00Z")!
        let summary = quotaSummary(fiveHourReset: fiveHour, weeklyReset: weekly)
        let est = provider.renewalEstimate(
            profile: makeProfile(), summary: summary, now: .distantPast)
        XCTAssertEqual(est?.date, weekly, "weekly window outranks the 5h rolling window")
        XCTAssertEqual(est?.prefix, "Weekly resets")
        XCTAssertEqual(est?.absolute, false)
    }

    func test_renewalEstimate_fallsBackToFiveHour_whenNoWeeklyWindow() {
        // Degenerate payload with only a 5h bucket: still surface something
        // honest rather than nothing.
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let fiveHour = ISO8601DateFormatter().date(from: "2026-05-29T02:00:00Z")!
        let summary = quotaSummary(fiveHourReset: fiveHour, weeklyReset: nil)
        let est = provider.renewalEstimate(
            profile: makeProfile(), summary: summary, now: .distantPast)
        XCTAssertEqual(est?.date, fiveHour, "no weekly bucket → soonest available reset")
        XCTAssertEqual(est?.prefix, "Resets")
    }

    func test_renewalEstimate_observedAnchorWins_overQuotaReset() {
        // Header estimate must keep the stable credit cycle once observed —
        // a transient quota cooldown in the summary must NOT replace it.
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let quotaReset = ISO8601DateFormatter().date(from: "2026-05-29T04:00:00Z")!
        let summary = quotaSummary(fiveHourReset: quotaReset, weeklyReset: nil)
        var profile = makeProfile()
        profile.observedCreditResetAt = ISO8601DateFormatter().date(from: "2026-04-18T00:00:00Z")
        let est = provider.renewalEstimate(
            profile: profile, summary: summary,
            now: ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!)
        XCTAssertEqual(est?.date, ISO8601DateFormatter().date(from: "2026-06-18T00:00:00Z"),
                       "observed cycle must win over the quota cooldown")
        XCTAssertEqual(est?.prefix, "Est. credits reset")
        XCTAssertEqual(est?.absolute, true)
    }

    func test_renewalEstimate_nilWhenNoAnchorAndNoQuota() {
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let payload = AntigravityUsagePayload(
            snapshot: AntigravityUsageSnapshot(fetchedAt: .distantPast), quota: nil)
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: .distantPast,
            primary: nil, secondary: nil, payload: payload)
        XCTAssertNil(provider.renewalEstimate(profile: makeProfile(), summary: summary, now: Date()))
    }

    // MARK: - switcherRenewalEstimate

    func test_switcherRenewalEstimate_followsWorstFiveHourGroupReset() {
        // The switcher row text sits beside the 5h bar (worst-group 5h window),
        // so it must track that bucket's own reset.
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let now = ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!
        let fiveHour = now.addingTimeInterval(4 * 3_600)
        let weekly = now.addingTimeInterval(5 * 86_400)
        let summary = quotaSummary(fiveHourReset: fiveHour, weeklyReset: weekly)
        let est = provider.switcherRenewalEstimate(profile: makeProfile(), summary: summary, now: now)
        XCTAssertEqual(est?.date, fiveHour, "must follow the worst-group 5h bucket")
        XCTAssertEqual(est?.prefix, "5-hour resets")
    }

    func test_switcherRenewalEstimate_fiveHourWinsOverObservedAnchor() {
        // The row text sits beside the 5h bar, so its reset outranks the
        // observed credit cycle here (unlike the header estimate).
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let reset = ISO8601DateFormatter().date(from: "2026-06-03T02:00:00Z")!
        let summary = quotaSummary(fiveHourReset: reset, weeklyReset: nil)
        var profile = makeProfile()
        profile.observedCreditResetAt = ISO8601DateFormatter().date(from: "2026-04-18T00:00:00Z")
        let est = provider.switcherRenewalEstimate(
            profile: profile, summary: summary,
            now: ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!)
        XCTAssertEqual(est?.date, reset)
        XCTAssertEqual(est?.prefix, "5-hour resets")
    }

    func test_switcherRenewalEstimate_fallsBackToCreditCycle_whenNoFiveHourReset() {
        // No 5h bucket reset → defer to the account-level estimate (observed
        // credit cycle).
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let summary = quotaSummary(fiveHourReset: nil, weeklyReset: nil)
        var profile = makeProfile()
        profile.observedCreditResetAt = ISO8601DateFormatter().date(from: "2026-04-18T00:00:00Z")
        let est = provider.switcherRenewalEstimate(
            profile: profile, summary: summary,
            now: ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!)
        XCTAssertEqual(est?.date, ISO8601DateFormatter().date(from: "2026-06-18T00:00:00Z"))
        XCTAssertEqual(est?.prefix, "Est. credits reset")
        XCTAssertEqual(est?.absolute, true)
    }

    func test_switcherRenewalEstimate_noFiveHourReset_noCycle_returnsNil() {
        // No 5h bucket reset and no observed cycle → nothing honest to show.
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let now = ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!
        let summary = quotaSummary(fiveHourReset: nil, weeklyReset: now.addingTimeInterval(4 * 3_600))
        let est = provider.switcherRenewalEstimate(profile: makeProfile(), summary: summary, now: now)
        XCTAssertNil(est, "must not borrow the weekly bucket's reset for the 5h row")
    }

    func test_switcherRenewalEstimate_weeklyExhausted_showsWeeklyResetNotFiveHour() {
        // When the group's weekly allowance is spent, the 5-hour window can't
        // be used until the weekly resets, so the countdown follows the weekly.
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let now = ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!
        let fiveHour = now.addingTimeInterval(4 * 3_600)
        let weekly = now.addingTimeInterval(2 * 86_400)
        let summary = quotaSummary(fiveHourReset: fiveHour, weeklyReset: weekly, weeklyRemaining: 0)
        let est = provider.switcherRenewalEstimate(profile: makeProfile(), summary: summary, now: now)
        XCTAssertEqual(est?.date, weekly, "weekly is the binding window once exhausted")
        XCTAssertEqual(est?.prefix, "Weekly resets")
    }

    func test_switcherRenewalEstimate_weeklyHasHeadroom_staysOnFiveHour() {
        // Weekly not exhausted → 5-hour remains the relevant countdown.
        let provider = makeProvider(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, watcher: StubAntigravityProcessWatcher())
        let now = ISO8601DateFormatter().date(from: "2026-05-29T00:00:00Z")!
        let fiveHour = now.addingTimeInterval(4 * 3_600)
        let weekly = now.addingTimeInterval(2 * 86_400)
        let summary = quotaSummary(fiveHourReset: fiveHour, weeklyReset: weekly, weeklyRemaining: 0.3)
        let est = provider.switcherRenewalEstimate(profile: makeProfile(), summary: summary, now: now)
        XCTAssertEqual(est?.date, fiveHour)
        XCTAssertEqual(est?.prefix, "5-hour resets")
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
                             primary: nil, secondary: nil,
                             payload: AntigravityUsagePayload(snapshot: snap, quota: nil))
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
