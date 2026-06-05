//
//  AutoProfileMigratorTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

@MainActor
final class AutoProfileMigratorTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    private func makeStore() -> ProfileStore {
        let keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let dataRoot = temp.url
        return ProfileStore(
            profilesFile: temp.file("profiles.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in dataRoot.appendingPathComponent(id.uuidString) }
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    private func oauth(email: String) -> OAuthAccountReader.Account {
        OAuthAccountReader.Account(seatTier: "pro",
                                    emailAddress: email,
                                    displayName: nil,
                                    organizationName: "Org",
                                    subscriptionCreatedAt: nil,
                                    organizationType: nil,
                                    organizationRateLimitTier: nil)
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func test_noProfiles_oauthPresent_createsAutoProfile() {
        let store = makeStore()
        AutoProfileMigrator(profileStore: store,
                            oauthRead: { self.oauth(email: "a@x.com") },
                            clock: { self.t0 },
                            defaults: makeDefaults()).runIfNeeded()
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].email, "a@x.com")
        XCTAssertEqual(store.profiles[0].kind, .auto)
        XCTAssertEqual(store.profiles[0].ownershipBoundary, t0)
        XCTAssertEqual(store.activeProfileId, store.profiles[0].id)
    }

    func test_profileEmailMatchesOauth_promotesAuto_keepsHistory() throws {
        let store = makeStore()
        var legacy = Profile(name: "Old", authMethod: .cliSync,
                              organizationId: "org-1", email: "a@x.com")
        legacy.kind = .archived
        try store.add(legacy)
        let originalId = legacy.id

        AutoProfileMigrator(profileStore: store,
                            oauthRead: { self.oauth(email: "a@x.com") },
                            clock: { self.t0 },
                            defaults: makeDefaults()).runIfNeeded()

        let promoted = store.profiles.first(where: { $0.id == originalId })!
        XCTAssertEqual(promoted.kind, .auto)
        XCTAssertEqual(store.activeProfileId, originalId)
        XCTAssertNotNil(promoted.ownershipBoundary)
    }

    func test_profileEmailMismatch_marksArchived() throws {
        let store = makeStore()
        try store.add(Profile(name: "Mismatch", authMethod: .sessionKey,
                              organizationId: "org-x", email: "z@x.com"))
        AutoProfileMigrator(profileStore: store,
                            oauthRead: { self.oauth(email: "a@x.com") },
                            clock: { self.t0 },
                            defaults: makeDefaults()).runIfNeeded()
        let mismatch = store.profiles.first { $0.email == "z@x.com" }!
        XCTAssertEqual(mismatch.kind, .archived)
        XCTAssertNotEqual(store.activeProfileId, mismatch.id)
    }

    func test_noOauth_archivesAll_noActiveProfile() throws {
        let store = makeStore()
        try store.add(Profile(name: "P", authMethod: .cliSync,
                              organizationId: "o", email: "a@x.com"))
        AutoProfileMigrator(profileStore: store,
                            oauthRead: { nil },
                            clock: { self.t0 },
                            defaults: makeDefaults()).runIfNeeded()
        XCTAssertEqual(store.profiles[0].kind, .archived)
        XCTAssertNil(store.activeProfileId,
                     "no oauth → migrator clears active so popover doesn't briefly render archived profile")
    }

    func test_idempotent_secondRunNoOp() {
        let store = makeStore()
        let defaults = makeDefaults()
        let migrator = AutoProfileMigrator(profileStore: store,
                                            oauthRead: { self.oauth(email: "a@x.com") },
                                            clock: { self.t0 },
                                            defaults: defaults)
        migrator.runIfNeeded()
        XCTAssertEqual(store.profiles.count, 1)
        let firstId = store.profiles[0].id
        migrator.runIfNeeded()    // second call
        XCTAssertEqual(store.profiles.count, 1, "second run must not duplicate")
        XCTAssertEqual(store.profiles[0].id, firstId)
    }

    func test_runIfNeeded_doesNotArchiveCodexProfiles_whenClaudeOauthIsNil() throws {
        // Seed a Codex profile (kind=.auto) — Claude's migrator must leave it alone.
        let store = makeStore()
        let codex = Profile(
            name: "Codex",
            authMethod: .cliSync,
            providerID: .codex,
            email: "codex-user@example.com",
            kind: .auto,
            ownershipBoundary: t0
        )
        try store.add(codex)

        let migrator = AutoProfileMigrator(
            profileStore: store,
            oauthRead: { nil },           // no Claude oauth
            clock: { self.t0 },
            defaults: makeDefaults()
        )
        migrator.runIfNeeded()

        let stored = store.profiles.first { $0.id == codex.id }
        XCTAssertEqual(stored?.kind, .auto,
                       "Claude's migrator must not touch a Codex profile when its own oauthRead returns nil")
    }

    func test_promote_syncsMetadata_fromOAuthAccount() throws {
        // Legacy profile has stale / no plan info. After migrator runs,
        // subscriptionPlan and name should reflect what oauth carries.
        let store = makeStore()
        var legacy = Profile(name: "old-name", authMethod: .cliSync,
                              organizationId: "org-1", email: "a@x.com")
        legacy.kind = .archived
        try store.add(legacy)
        let freshOAuth = OAuthAccountReader.Account(
            seatTier: nil,
            emailAddress: "a@x.com",
            displayName: "Hau Nguyen",
            organizationName: "Org",
            subscriptionCreatedAt: nil,
            organizationType: "claude_max",
            organizationRateLimitTier: nil
        )
        AutoProfileMigrator(profileStore: store,
                            oauthRead: { freshOAuth },
                            clock: { self.t0 },
                            defaults: makeDefaults()).runIfNeeded()
        let promoted = store.profiles.first(where: { $0.id == legacy.id })!
        XCTAssertEqual(promoted.subscriptionPlan, "Max",
                       "migrator should derive plan from organizationType when seatTier is nil")
        XCTAssertEqual(promoted.name, "Hau Nguyen",
                       "migrator should update name from oauth displayName")
    }
}
