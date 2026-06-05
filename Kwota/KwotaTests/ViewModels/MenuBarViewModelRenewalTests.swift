//
//  MenuBarViewModelRenewalTests.swift
//  KwotaTests
//
//  Locks the precedence rule in MenuBarViewModel.subscriptionRenewsAt:
//  an explicit Profile.subscriptionRenewsAt wins outright over the
//  monthly-anniversary extrapolation from subscriptionCreatedAt. Also
//  locks the provider-aware tooltip copy so accidental wording drift
//  fails CI.
//

import XCTest
@testable import Kwota

@MainActor
final class MenuBarViewModelRenewalTests: XCTestCase {
    private var temp: TempDirectory!
    private var keychain: KeychainCredentialStore!
    private var profileStore: ProfileStore!

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
    }

    override func tearDown() async throws {
        try? keychain.deleteAll()
        try await super.tearDown()
    }

    /// Mirrors the makeVM pattern in MenuBarViewModelPreloadedSummaryTests —
    /// two separate watcher instances to keep the VM's start()-time nil
    /// emits from racing into the coordinator's onChange.
    private func makeVM() -> MenuBarViewModel {
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
        let codexVMWatcher = CodexAccountWatcher(
            authRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let codexCoordWatcher = CodexAccountWatcher(
            authRead: { nil },
            fileEvents: AsyncStream { _ in }
        )
        let codexCoordStub = CodexAutoProfileCoordinator(
            watcher: codexCoordWatcher,
            profileStore: profileStore,
            keychain: keychain,
            clock: { Date() }
        )
        let antigravityWatcherVM = AntigravityProcessWatcher(detect: { nil })
        let antigravityWatcherCoord = AntigravityProcessWatcher(detect: { nil })
        let antigravityCoordStub = AntigravityAutoProfileCoordinator(
            watcher: antigravityWatcherCoord,
            profileStore: profileStore
        )
        let sandboxedDefaults = UserDefaults(suiteName: "kwota-renewal-test-\(UUID())")!
        sandboxedDefaults.set(true, forKey: "autoDetectMigrationCompleted")
        let inertMigrator = AutoProfileMigrator(
            profileStore: profileStore,
            oauthRead: { nil },
            defaults: sandboxedDefaults
        )
        let usage = UsageMonitor(
            reader: FakeJSONLogReader(),
            ledgerURL: temp.file("ledger-\(UUID().uuidString).json"),
            dailyCounterURL: temp.file("daily-counter-\(UUID().uuidString).json")
        )
        let stubClient = ClaudeAPIClient(transport: { req in
            let url = req.url ?? URL(string: "https://example.invalid")!
            let resp = HTTPURLResponse(url: url, statusCode: 401,
                                       httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        })
        return MenuBarViewModel(
            usage: usage,
            profileStore: profileStore,
            credentialStore: keychain,
            apiClient: stubClient,
            activitySource: CompositeActivitySource(sources: []),
            cliAccountWatcher: vmWatcher,
            codexAccountWatcher: codexVMWatcher,
            antigravityProcessWatcher: antigravityWatcherVM,
            autoProfileCoordinator: permissiveCoord,
            codexAutoProfileCoordinator: codexCoordStub,
            antigravityAutoProfileCoordinator: antigravityCoordStub,
            autoProfileMigrator: inertMigrator,
            now: { Date() }
        )
    }

    // MARK: - Precedence

    func test_explicitRenewsAt_winsOverExtrapolation() throws {
        // Profile carries BOTH an explicit renewal date AND a creation
        // anchor. The explicit field must win — extrapolation must never
        // run when we already have a real date.
        let explicit = Date(timeIntervalSince1970: 1_780_000_000)
        let createdAt = Date(timeIntervalSince1970: 1_500_000_000)
        let p = Profile(
            name: "Hau",
            authMethod: .cliSync,
            providerID: .codex,
            createdAt: Date(),
            subscriptionCreatedAt: createdAt,
            subscriptionRenewsAt: explicit,
            email: "u@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
        try profileStore.add(p)
        try profileStore.setActive(id: p.id)

        let vm = makeVM()
        XCTAssertEqual(vm.subscriptionRenewsAt?.timeIntervalSince1970.rounded(),
                       explicit.timeIntervalSince1970.rounded(),
                       "Explicit subscriptionRenewsAt must win over extrapolation")
    }

    func test_extrapolationFallback_whenExplicitIsNil() throws {
        // Profile with subscriptionCreatedAt only — the Claude pathway.
        let createdAt = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
        let p = Profile(
            name: "User",
            authMethod: .cliSync,
            providerID: .claude,
            createdAt: Date(),
            subscriptionCreatedAt: createdAt,
            subscriptionRenewsAt: nil,
            email: "c@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
        try profileStore.add(p)
        try profileStore.setActive(id: p.id)

        let vm = makeVM()
        XCTAssertNotNil(vm.subscriptionRenewsAt,
                        "Claude fallback extrapolation must return a date when subscriptionCreatedAt is set")
    }

    func test_nilWhenBothAnchorsMissing() throws {
        let p = Profile(
            name: "User",
            authMethod: .cliSync,
            providerID: .codex,
            createdAt: Date(),
            email: "u@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
        try profileStore.add(p)
        try profileStore.setActive(id: p.id)

        let vm = makeVM()
        XCTAssertNil(vm.subscriptionRenewsAt,
                     "VM returns nil when neither explicit field nor creation anchor is set")
    }

    // MARK: - Tooltip wording

    func test_tooltip_codexCopyMentionsJwt() throws {
        let p = Profile(
            name: "Hau",
            authMethod: .cliSync,
            providerID: .codex,
            email: "u@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
        try profileStore.add(p)
        try profileStore.setActive(id: p.id)

        let vm = makeVM()
        XCTAssertTrue(vm.subscriptionRenewalTooltip.contains("id_token"),
                      "Codex tooltip must mention id_token as the data source — got: \(vm.subscriptionRenewalTooltip)")
    }

    func test_tooltip_claudeCopyMentionsApproximation() throws {
        let p = Profile(
            name: "Claude",
            authMethod: .cliSync,
            providerID: .claude,
            email: "c@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
        try profileStore.add(p)
        try profileStore.setActive(id: p.id)

        let vm = makeVM()
        XCTAssertTrue(vm.subscriptionRenewalTooltip.contains("Approximation"),
                      "Claude tooltip must explain the monthly approximation — got: \(vm.subscriptionRenewalTooltip)")
    }

    // MARK: - Static estimatedRenewal helper (pure)
    //
    // These tests do NOT use `makeVM()` — the whole point of the
    // extraction is to test the renewal logic without spinning up
    // watchers, ProfileStore, or KeychainCredentialStore.

    func test_estimatedRenewal_explicitFieldWins() {
        let explicit = Date(timeIntervalSince1970: 1_800_000_000)
        let createdAt = Date(timeIntervalSince1970: 1_500_000_000)
        let p = Profile(
            name: "Hau",
            authMethod: .cliSync,
            providerID: .codex,
            createdAt: Date(),
            subscriptionCreatedAt: createdAt,
            subscriptionRenewsAt: explicit,
            email: "u@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
        let result = MenuBarViewModel.estimatedRenewal(for: p, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(result?.timeIntervalSince1970.rounded(),
                       explicit.timeIntervalSince1970.rounded(),
                       "Static helper must return the explicit field verbatim")
    }

    func test_estimatedRenewal_extrapolatesFromCreatedAtPastNow() {
        // CreatedAt 3 months ago; expect next monthly anniversary
        // strictly AFTER now.
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let createdAt = Calendar.current.date(byAdding: .month, value: -3, to: now)!
        let p = Profile(
            name: "User",
            authMethod: .cliSync,
            providerID: .claude,
            createdAt: Date(),
            subscriptionCreatedAt: createdAt,
            subscriptionRenewsAt: nil,
            email: "c@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
        let result = MenuBarViewModel.estimatedRenewal(for: p, now: now)
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result!, now,
                             "Extrapolated renewal must be strictly after `now`")
        let oneMonthAfterNow = Calendar.current.date(byAdding: .month, value: 1, to: now)!
        XCTAssertLessThanOrEqual(result!, oneMonthAfterNow,
                                 "Extrapolated renewal must be within one month of `now`")
    }

    func test_estimatedRenewal_nilWhenBothAnchorsMissing() {
        let p = Profile(
            name: "User",
            authMethod: .cliSync,
            providerID: .codex,
            createdAt: Date(),
            email: "u@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
        let result = MenuBarViewModel.estimatedRenewal(for: p, now: Date())
        XCTAssertNil(result,
                     "Static helper returns nil when neither anchor is set")
    }

    func test_estimatedRenewal_returnsCreatedAtWhenInFuture() {
        // Edge case matching the existing instance-getter behavior:
        // when subscriptionCreatedAt is in the future (test fixtures,
        // clock skew, etc.) we surface it verbatim rather than looping.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let createdAt = Calendar.current.date(byAdding: .month, value: 2, to: now)!
        let p = Profile(
            name: "User",
            authMethod: .cliSync,
            providerID: .claude,
            createdAt: Date(),
            subscriptionCreatedAt: createdAt,
            subscriptionRenewsAt: nil,
            email: "c@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
        let result = MenuBarViewModel.estimatedRenewal(for: p, now: now)
        XCTAssertEqual(result?.timeIntervalSince1970.rounded(),
                       createdAt.timeIntervalSince1970.rounded(),
                       "Future createdAt is surfaced as-is — matches instance-getter fall-through")
    }
}
