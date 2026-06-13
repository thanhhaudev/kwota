//
//  AntigravityProviderEndToEndTests.swift
//  KwotaTests
//
//  Exercises the full Antigravity profile lifecycle in a single test:
//  Antigravity app starts (watcher emits identity) → coordinator creates
//  an active .auto profile → provider fetches usage and back-fills email
//  → app exits (watcher emits nil) → coordinator archives profile → app
//  restarts (watcher emits new identity, rotated CSRF) → coordinator
//  promotes the archived profile back to .auto.
//
//  All collaborators are stubbed (no real ps/lsof, no real localhost
//  server); the test verifies the wiring, not the I/O.
//

import XCTest
@testable import Kwota

@MainActor
final class AntigravityProviderEndToEndTests: XCTestCase {
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

    func test_fullLifecycle_login_fetch_logout_archive_relogin_promote() async throws {
        let watcher = StubAntigravityProcessWatcher()
        let coordinator = AntigravityAutoProfileCoordinator(
            watcher: watcher,
            profileStore: profileStore,
            clock: { Date() }
        )
        coordinator.start()

        // GetUserStatus response captured from a real Antigravity Pro account
        // (PII scrubbed). The provider must back-fill email + name + plan.
        let liveBody = #"""
        {"userStatus":{
          "name":"Test User","email":"test@example.com",
          "planStatus":{
            "planInfo":{"planName":"Pro","monthlyPromptCredits":50000,"monthlyFlowCredits":150000},
            "availablePromptCredits":12500,
            "availableFlowCredits":42000
          },
          "cascadeModelConfigData":{"clientModelConfigs":[
            {"label":"Gemini 3.5 Flash (Medium)","modelOrAlias":{"model":"M20"},
             "quotaInfo":{"remainingFraction":0.85,"resetTime":"2026-05-28T00:00:00Z"}}
          ]}
        }}
        """#
        let apiClient = AntigravityAPIClient(transport: { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (Data(liveBody.utf8), resp)
        })
        let provider = AntigravityProvider(
            apiClient: apiClient,
            watcher: watcher,
            profileStore: profileStore,
            readModelCredits: { nil }
        )

        // === 1. App appears: identity emitted, coordinator creates profile.
        let id1 = AntigravityIdentity(csrfToken: "csrf-A", port: 49838,
                                       credentialFingerprint: "fp-A")
        watcher.emit(id1)
        guard let activeId = profileStore.activeProfileId,
              let active = profileStore.profiles.first(where: { $0.id == activeId }) else {
            XCTFail("coordinator should have created an active Antigravity profile")
            return
        }
        XCTAssertEqual(active.providerID, .antigravity)
        XCTAssertEqual(active.kind, .auto)
        XCTAssertNil(active.email, "no email at create-time — comes from fetch")

        // === 2. Provider fetchUsage returns a summary, profile is back-filled.
        let summary = try await provider.fetchUsage(
            credential: .cliToken(accessToken: "ignored", refreshToken: "", expiresAt: .distantFuture),
            profile: active
        )
        XCTAssertEqual(summary.providerID, .antigravity)
        let payload = try XCTUnwrap(summary.payload as? AntigravityUsagePayload)
        XCTAssertEqual(payload.snapshot.email, "test@example.com")

        let afterFetch = try XCTUnwrap(profileStore.profiles.first(where: { $0.id == active.id }))
        XCTAssertEqual(afterFetch.email, "test@example.com")
        XCTAssertEqual(afterFetch.name, "Test User")
        XCTAssertEqual(afterFetch.subscriptionPlan, "Pro")

        // === 3. App exits: identity nil, coordinator archives.
        watcher.emit(nil)
        let afterLogout = try XCTUnwrap(profileStore.profiles.first(where: { $0.id == active.id }))
        XCTAssertEqual(afterLogout.kind, .archived, "should be archived on process gone")
        XCTAssertNil(profileStore.activeProfileId)

        // === 4. App restarts with rotated CSRF: archived profile promoted back.
        let id2 = AntigravityIdentity(csrfToken: "csrf-B-rotated", port: 50000,
                                       credentialFingerprint: "fp-B")
        watcher.emit(id2)
        let afterReopen = try XCTUnwrap(profileStore.profiles.first(where: { $0.id == active.id }))
        XCTAssertEqual(afterReopen.kind, .auto, "archived profile must be promoted, not duplicated")
        XCTAssertEqual(afterReopen.email, "test@example.com", "email survives the archive→auto roundtrip")
        XCTAssertEqual(profileStore.activeProfileId, active.id)

        // No duplicate profiles created.
        let antigravityProfiles = profileStore.profiles.filter { $0.providerID == .antigravity }
        XCTAssertEqual(antigravityProfiles.count, 1, "exactly one Antigravity profile across the cycle")
    }
}
