//
//  ProfileStoreTests.swift
//  KwotaTests
//

import XCTest
import Combine
@testable import Kwota

@MainActor
final class ProfileStoreTests: XCTestCase {
    private var temp: TempDirectory!
    private var store: ProfileStore!

    private func makeKeychain() -> KeychainCredentialStore {
        KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID().uuidString)")
    }

    private func makeStore() -> ProfileStore {
        let keychain = makeKeychain()
        return ProfileStore(
            profilesFile: temp.file("profiles-\(UUID().uuidString).json"),
            keychain: keychain
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
        store = ProfileStore(profilesFile: temp.file("profiles.json"), keychain: makeKeychain())
    }

    func testStartsEmpty() {
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.activeProfileId)
    }

    func testAddPersistsAndSetsFirstAsActive() throws {
        let p = Profile(name: "First", authMethod: .cliSync)
        try store.add(p)
        XCTAssertEqual(store.profiles, [p])
        XCTAssertEqual(store.activeProfileId, p.id)

        // Reload from disk and re-check.
        let reload = ProfileStore(profilesFile: temp.file("profiles.json"), keychain: makeKeychain())
        XCTAssertEqual(reload.profiles, [p])
        XCTAssertEqual(reload.activeProfileId, p.id)
    }

    func testAddSecondLeavesFirstActive() throws {
        let p1 = Profile(name: "A", authMethod: .cliSync)
        let p2 = Profile(name: "B", authMethod: .sessionKey)
        try store.add(p1)
        try store.add(p2)
        XCTAssertEqual(store.profiles.map(\.id), [p1.id, p2.id])
        XCTAssertEqual(store.activeProfileId, p1.id)
    }

    func testRenameUpdatesNameInMemoryAndOnDisk() throws {
        let p = Profile(name: "Old", authMethod: .cliSync)
        try store.add(p)
        try store.rename(id: p.id, to: "New")
        XCTAssertEqual(store.profiles.first?.name, "New")

        let reload = ProfileStore(profilesFile: temp.file("profiles.json"), keychain: makeKeychain())
        XCTAssertEqual(reload.profiles.first?.name, "New")
    }

    func testSetActiveSwitchesPointer() throws {
        let p1 = Profile(name: "A", authMethod: .cliSync)
        let p2 = Profile(name: "B", authMethod: .sessionKey)
        try store.add(p1)
        try store.add(p2)
        try store.setActive(id: p2.id)
        XCTAssertEqual(store.activeProfileId, p2.id)
    }

    func testSetActiveUnknownIDThrows() throws {
        XCTAssertThrowsError(try store.setActive(id: UUID()))
    }

    func testRemoveDeletesProfileAndCascadesToKeychainAndDisk() throws {
        let keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let dataRoot = temp.file("data-root")
        let store = ProfileStore(
            profilesFile: temp.file("profiles2.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in dataRoot.appendingPathComponent(id.uuidString) }
        )

        let p = Profile(name: "ToRemove", authMethod: .sessionKey)
        try store.add(p)
        try keychain.write(.sessionKey(value: "x"), for: p.id)

        let pdir = dataRoot.appendingPathComponent(p.id.uuidString)
        try FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: pdir.appendingPathComponent("usage-history.json"))

        try store.remove(id: p.id)

        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.activeProfileId)
        XCTAssertNil(try keychain.read(for: p.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdir.path))
    }

    func testProfileWithLastSnapshotRoundTripsThroughDisk() throws {
        let snap = UsageSnapshot(
            fiveHour: UsageBucket(utilization: 45, resetsAt: Date(timeIntervalSince1970: 1700000000)),
            sevenDay: UsageBucket(utilization: 60, resetsAt: Date(timeIntervalSince1970: 1700500000)),
            fetchedAt: Date(timeIntervalSince1970: 1700000010)
        )
        var p = Profile(name: "P", authMethod: .sessionKey)
        p.lastSnapshot = snap
        p.lastSessionPercentage = 45
        try store.add(p)

        let reload = ProfileStore(profilesFile: temp.file("profiles.json"), keychain: makeKeychain())
        XCTAssertEqual(reload.profiles.first?.lastSnapshot?.fiveHour.utilization, 45)
        XCTAssertEqual(reload.profiles.first?.lastSnapshot?.fetchedAt.timeIntervalSince1970, 1700000010)
        XCTAssertEqual(reload.profiles.first?.lastSessionPercentage, 45)
    }

    func testUpdateProfileReplacesInPlaceAndPersists() throws {
        let p = Profile(name: "P", authMethod: .sessionKey)
        try store.add(p)
        var updated = p
        updated.organizationId = "org-x"
        updated.lastSessionPercentage = 73
        try store.updateProfile(updated)
        XCTAssertEqual(store.profiles.first?.organizationId, "org-x")
        XCTAssertEqual(store.profiles.first?.lastSessionPercentage, 73)

        let reload = ProfileStore(profilesFile: temp.file("profiles.json"), keychain: makeKeychain())
        XCTAssertEqual(reload.profiles.first?.organizationId, "org-x")
        XCTAssertEqual(reload.profiles.first?.lastSessionPercentage, 73)
    }

    func testProfilePersistsSessionKeyExpiresAt() throws {
        let expiry = Date(timeIntervalSince1970: 1900000000)
        var p = Profile(name: "Web", authMethod: .sessionKey)
        p.sessionKeyExpiresAt = expiry
        try store.add(p)

        let reload = ProfileStore(profilesFile: temp.file("profiles.json"), keychain: makeKeychain())
        XCTAssertEqual(
            reload.profiles.first?.sessionKeyExpiresAt?.timeIntervalSince1970,
            1900000000
        )
    }

    func testRemoveActiveAdvancesToNextProfile() throws {
        let keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let store = ProfileStore(
            profilesFile: temp.file("profiles3.json"),
            keychain: keychain,
            profileDirectoryProvider: { _ in self.temp.file("never") }
        )
        let p1 = Profile(name: "A", authMethod: .cliSync)
        let p2 = Profile(name: "B", authMethod: .sessionKey)
        try store.add(p1)
        try store.add(p2)
        try store.setActive(id: p1.id)
        try store.remove(id: p1.id)
        XCTAssertEqual(store.activeProfileId, p2.id)
    }

    // MARK: - findMatching(email:orgId:)

    func test_findMatching_emailAndOrgId_caseInsensitive() throws {
        let p = Profile(name: "A", authMethod: .cliSync,
                        organizationId: "org-1", email: "Alice@x.com")
        try store.add(p)
        XCTAssertEqual(store.findMatching(providerID: .claude, email: "alice@x.com", orgId: "org-1")?.id, p.id)
        XCTAssertEqual(store.findMatching(providerID: .claude, email: "ALICE@x.com", orgId: "org-1")?.id, p.id)
    }

    func test_findMatching_returnsNil_whenEmailMatchesButOrgIdDoesNot() throws {
        let p = Profile(name: "A", authMethod: .cliSync,
                        organizationId: "org-1", email: "a@x.com")
        try store.add(p)
        XCTAssertNil(store.findMatching(providerID: .claude, email: "a@x.com", orgId: "org-2"))
    }

    func test_findMatching_returnsNil_whenEitherSideIsNil() throws {
        let p = Profile(name: "A", authMethod: .cliSync,
                        organizationId: nil, email: "a@x.com")
        try store.add(p)
        XCTAssertNil(store.findMatching(providerID: .claude, email: "a@x.com", orgId: nil))
        XCTAssertNil(store.findMatching(providerID: .claude, email: nil, orgId: "org-1"))
    }

    func test_findMatching_doesNotMatchDifferentProvider() throws {
        let foreign = Profile(
            name: "Other",
            authMethod: .cliSync,
            providerID: .codex,
            organizationId: "org-1",
            email: "a@x.com",
            kind: .auto
        )
        try store.add(foreign)
        XCTAssertNil(
            store.findMatching(providerID: .claude, email: "a@x.com", orgId: "org-1"),
            "claude lookup must not return a profile bound to a different provider"
        )
    }

    // MARK: - findAutoByEmail(_:)

    func test_findAutoByEmail_caseInsensitive_returnsAutoProfile() throws {
        let p = Profile(name: "A", authMethod: .cliSync,
                        organizationId: nil, email: "Alice@x.com",
                        kind: .auto)
        try store.add(p)
        XCTAssertEqual(store.findAutoByEmail(providerID: .claude, "alice@x.com")?.id, p.id)
        XCTAssertEqual(store.findAutoByEmail(providerID: .claude, "ALICE@x.com")?.id, p.id)
    }

    func test_findAutoByEmail_skipsArchivedProfiles() throws {
        let p = Profile(name: "A", authMethod: .cliSync,
                        organizationId: nil, email: "a@x.com",
                        kind: .archived)
        try store.add(p)
        XCTAssertNil(store.findAutoByEmail(providerID: .claude, "a@x.com"),
                     "archived profiles must not be auto-reused")
    }

    func test_findAutoByEmail_nilOrEmptyEmail_returnsNil() {
        XCTAssertNil(store.findAutoByEmail(providerID: .claude, nil))
        XCTAssertNil(store.findAutoByEmail(providerID: .claude, ""))
    }

    func test_findAutoByEmail_doesNotMatchDifferentProvider() throws {
        let foreign = Profile(
            name: "Other",
            authMethod: .cliSync,
            providerID: .codex,
            organizationId: nil,
            email: "a@x.com",
            kind: .auto
        )
        try store.add(foreign)
        XCTAssertNil(
            store.findAutoByEmail(providerID: .claude, "a@x.com"),
            "claude lookup must not return a profile bound to a different provider"
        )
    }

    // MARK: - findArchivedByEmail(_:)

    func test_findArchivedByEmail_returnsArchivedProfile() throws {
        var p = Profile(name: "Old", authMethod: .cliSync,
                        providerID: .claude, organizationId: nil,
                        email: "a@x.com")
        p.kind = .archived
        try store.add(p)
        XCTAssertEqual(store.findArchivedByEmail(providerID: .claude, "a@x.com")?.id, p.id)
    }

    func test_findArchivedByEmail_skipsAutoProfile() throws {
        let p = Profile(name: "A", authMethod: .cliSync,
                        providerID: .claude, organizationId: nil,
                        email: "a@x.com", kind: .auto)
        try store.add(p)
        XCTAssertNil(store.findArchivedByEmail(providerID: .claude, "a@x.com"),
                     "auto profile must not be returned to the archived cascade")
    }

    func test_findArchivedByEmail_scopedByProvider() throws {
        var foreign = Profile(name: "Foreign", authMethod: .cliSync,
                              providerID: .codex,
                              organizationId: nil, email: "a@x.com")
        foreign.kind = .archived
        try store.add(foreign)
        XCTAssertNil(store.findArchivedByEmail(providerID: .claude, "a@x.com"),
                     "different-provider archived profile must not match Claude lookup")
    }

    func test_findArchivedByEmail_nilOrEmptyEmail_returnsNil() {
        XCTAssertNil(store.findArchivedByEmail(providerID: .claude, nil))
        XCTAssertNil(store.findArchivedByEmail(providerID: .claude, ""))
    }

    // MARK: - remove throws RemoveError on side-state failure

    /// When the profile directory cannot be removed, remove() must:
    /// 1. Still persist the removal (profile absent from profiles.json), and
    /// 2. Throw RemoveError.sideStateLingered with a non-nil directoryError.
    func test_remove_throwsRemoveError_whenDirectoryDeleteFails() throws {
        let keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")

        // Create a read-only child inside the profile directory so that
        // FileManager cannot delete the directory itself (requires write access).
        let profileDirRoot = temp.file("profile-dir-root")
        try FileManager.default.createDirectory(at: profileDirRoot, withIntermediateDirectories: true)

        let profileStore = ProfileStore(
            profilesFile: temp.file("profiles-remove-err.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in profileDirRoot.appendingPathComponent(id.uuidString) }
        )

        let p = Profile(name: "ToFail", authMethod: .cliSync)
        try profileStore.add(p)

        // Create the profile dir with a child, then lock it read-only.
        let profileDir = profileDirRoot.appendingPathComponent(p.id.uuidString)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: profileDir.appendingPathComponent("history.json"))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o500))],
            ofItemAtPath: profileDir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: profileDir.path
            )
        }

        var caughtRemoveError: ProfileStore.RemoveError?
        do {
            try profileStore.remove(id: p.id)
        } catch let err as ProfileStore.RemoveError {
            caughtRemoveError = err
        } catch {
            XCTFail("unexpected error type: \(error)")
        }

        // Profile must be gone from the persisted list even though cleanup failed.
        let reload = ProfileStore(
            profilesFile: temp.file("profiles-remove-err.json"),
            keychain: keychain
        )
        XCTAssertTrue(reload.profiles.isEmpty, "profile must be absent from disk after remove")
        XCTAssertTrue(profileStore.profiles.isEmpty, "profile must be absent from memory after remove")

        // A RemoveError with a directoryError must have been thrown.
        guard case .sideStateLingered(let pid, _, let dirErr) = caughtRemoveError else {
            return XCTFail("expected sideStateLingered, got \(String(describing: caughtRemoveError))")
        }
        XCTAssertEqual(pid, p.id)
        XCTAssertNotNil(dirErr, "directoryError must be set when directory removal fails")
    }

    /// Keychain failure injection is not feasible without a protocol seam on
    /// ProfileStore's `keychain` field (it's `KeychainCredentialStore`, not a
    /// protocol). The keychainError branch of RemoveError.sideStateLingered is
    /// covered by code review and the directoryError test above. Skipped — gap
    /// documented here so future refactors know to add a protocol-based seam
    /// if keychain failure injection becomes a test requirement.
    func test_remove_throwsRemoveError_whenKeychainDeleteFails_SKIP() throws {
        throw XCTSkip("No protocol seam for keychain failure injection in ProfileStore; covered by test_remove_throwsRemoveError_whenDirectoryDeleteFails and code review")
    }

    // MARK: - apply(oauthProfile:for:)

    private func makeFullResponse(
        planLabel: String? = "Max 20x",
        accountUuid: String? = "acc-1",
        displayName: String? = "Hau",
        organizationName: String? = "Hau's Org",
        subscriptionStatus: String? = "active",
        billingType: String? = "stripe_subscription",
        hasExtraUsage: Bool? = false,
        subscriptionCreatedAt: Date? = Date(timeIntervalSince1970: 1_700_500_000),
        accountCreatedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> OAuthProfileFetcher.Response {
        OAuthProfileFetcher.Response(
            planLabel: planLabel,
            orgUuid: "org-1",
            subscriptionCreatedAt: subscriptionCreatedAt,
            subscriptionActive: subscriptionStatus == "active",
            hasExtraUsage: hasExtraUsage,
            displayName: displayName,
            email: "h@x.com",
            accountUuid: accountUuid,
            accountCreatedAt: accountCreatedAt,
            organizationName: organizationName,
            subscriptionStatus: subscriptionStatus,
            billingType: billingType
        )
    }

    func test_applyOAuthProfile_writesAllFields_whenStoreHasNone() throws {
        let store = makeStore()
        let profile = Profile(name: "Hau", authMethod: .cliSync, email: "h@x.com")
        try store.add(profile)

        let changed = try store.apply(oauthProfile: makeFullResponse(), for: profile.id)
        XCTAssertTrue(changed)

        let stored = store.profiles.first(where: { $0.id == profile.id })!
        XCTAssertEqual(stored.subscriptionPlan, "Max 20x")
        XCTAssertEqual(stored.accountUuid, "acc-1")
        XCTAssertEqual(stored.displayName, "Hau")
        XCTAssertEqual(stored.organizationName, "Hau's Org")
        XCTAssertEqual(stored.subscriptionStatus, "active")
        XCTAssertEqual(stored.billingType, "stripe_subscription")
        XCTAssertEqual(stored.hasExtraUsageEnabled, false)
        XCTAssertNotNil(stored.subscriptionCreatedAt)
        XCTAssertNotNil(stored.accountCreatedAt)
        XCTAssertEqual(stored.organizationId, "org-1",
                       "orgUuid from response must backfill organizationId")
    }

    func test_applyOAuthProfile_doesNotClobberFields_whenResponseHasNil() throws {
        let store = makeStore()
        let profile = Profile(
            name: "Hau", authMethod: .cliSync,
            subscriptionPlan: "Max 20x", email: "h@x.com",
            organizationName: "MyOrg",
            subscriptionStatus: "active",
            billingType: "stripe_subscription"
        )
        try store.add(profile)

        let nilledResponse = makeFullResponse(
            planLabel: nil,
            organizationName: nil,
            subscriptionStatus: nil,
            billingType: nil
        )
        _ = try store.apply(oauthProfile: nilledResponse, for: profile.id)

        let stored = store.profiles.first(where: { $0.id == profile.id })!
        XCTAssertEqual(stored.subscriptionPlan, "Max 20x",
                       "nil planLabel must not clobber stored value")
        XCTAssertEqual(stored.organizationName, "MyOrg",
                       "nil organizationName must not clobber stored value")
        XCTAssertEqual(stored.subscriptionStatus, "active",
                       "nil subscriptionStatus must not clobber stored value")
        XCTAssertEqual(stored.billingType, "stripe_subscription",
                       "nil billingType must not clobber stored value")
    }

    func test_applyOAuthProfile_doesNotClobberHasExtraUsage_whenResponseHasNil() throws {
        // Regression: stored hasExtraUsageEnabled=true must survive a
        // probe whose response omits the field. Mirror of Guard A for the
        // tri-state Bool case (the field used to be non-Optional Bool and
        // would clobber stored true with false on partial payloads).
        let store = makeStore()
        let profile = Profile(
            name: "Hau", authMethod: .cliSync,
            email: "h@x.com",
            hasExtraUsageEnabled: true
        )
        try store.add(profile)

        let nilledResponse = OAuthProfileFetcher.Response(
            planLabel: "Max 20x", orgUuid: "org-1", subscriptionCreatedAt: nil,
            subscriptionActive: true, hasExtraUsage: nil,
            displayName: nil, email: nil,
            accountUuid: nil, accountCreatedAt: nil, organizationName: nil,
            subscriptionStatus: "active", billingType: nil
        )
        _ = try store.apply(oauthProfile: nilledResponse, for: profile.id)

        let stored = store.profiles.first(where: { $0.id == profile.id })!
        XCTAssertEqual(stored.hasExtraUsageEnabled, true,
                       "nil hasExtraUsage must not clobber stored true value")
    }

    func test_applyOAuthProfile_writesHasExtraUsage_whenResponseHasValue() throws {
        // Companion: when response carries an explicit Bool that differs
        // from stored, the write fires normally.
        let store = makeStore()
        let profile = Profile(
            name: "Hau", authMethod: .cliSync,
            email: "h@x.com",
            hasExtraUsageEnabled: false
        )
        try store.add(profile)

        let response = OAuthProfileFetcher.Response(
            planLabel: nil, orgUuid: "org-1", subscriptionCreatedAt: nil,
            subscriptionActive: true, hasExtraUsage: true,
            displayName: nil, email: nil,
            accountUuid: nil, accountCreatedAt: nil, organizationName: nil,
            subscriptionStatus: nil, billingType: nil
        )
        let changed = try store.apply(oauthProfile: response, for: profile.id)
        XCTAssertTrue(changed)
        XCTAssertEqual(store.profiles.first(where: { $0.id == profile.id })?.hasExtraUsageEnabled, true)
    }

    func test_applyOAuthProfile_doesNotClobberOrganizationId_whenResponseHasNil() throws {
        // Regression: stored organizationId="org-A" must survive a probe
        // whose response.orgUuid is nil (degraded payload or unexpected
        // schema). Same Guard A invariant as the other nullable fields.
        let store = makeStore()
        let profile = Profile(
            name: "Hau", authMethod: .cliSync,
            organizationId: "org-A",
            email: "h@x.com"
        )
        try store.add(profile)

        let nilOrgResponse = OAuthProfileFetcher.Response(
            planLabel: "Max 20x", orgUuid: nil, subscriptionCreatedAt: nil,
            subscriptionActive: true, hasExtraUsage: nil,
            displayName: nil, email: nil,
            accountUuid: nil, accountCreatedAt: nil, organizationName: nil,
            subscriptionStatus: nil, billingType: nil
        )
        _ = try store.apply(oauthProfile: nilOrgResponse, for: profile.id)

        let stored = store.profiles.first(where: { $0.id == profile.id })!
        XCTAssertEqual(stored.organizationId, "org-A",
                       "nil orgUuid must not clobber stored organizationId")
    }

    func test_applyOAuthProfile_doesNotOverwriteOrganizationId_whenStoredNonNilAndDiffers() throws {
        // Regression for Codex round 4 (now strengthened in round 5): a
        // non-nil stored organizationId that differs from the response's
        // orgUuid must throw identityMismatch and refuse the ENTIRE merge,
        // not merely skip the orgId field. The realistic failure mode is a
        // same-email user switching CLI from org-A to org-B: the
        // coordinator's email-only fallback matches the org-A profile, seeds
        // org-B's credential, and the probe returns org-B's UUID. Partially
        // merging here would mix org-A identity with org-B plan/billing data.
        let store = makeStore()
        let profile = Profile(
            name: "Hau", authMethod: .cliSync,
            organizationId: "org-A",
            email: "h@x.com"
        )
        try store.add(profile)

        let response = OAuthProfileFetcher.Response(
            planLabel: nil, orgUuid: "org-B", subscriptionCreatedAt: nil,
            subscriptionActive: true, hasExtraUsage: nil,
            displayName: nil, email: nil,
            accountUuid: nil, accountCreatedAt: nil, organizationName: nil,
            subscriptionStatus: nil, billingType: nil
        )
        XCTAssertThrowsError(try store.apply(oauthProfile: response, for: profile.id)) { error in
            guard case ProfileStore.StoreError.identityMismatch = error else {
                XCTFail("expected identityMismatch, got \(error)")
                return
            }
        }
        XCTAssertEqual(
            store.profiles.first(where: { $0.id == profile.id })?.organizationId,
            "org-A",
            "stored non-nil organizationId must not be overwritten by a differing response.orgUuid"
        )
    }

    func test_applyOAuthProfile_returnsFalse_whenNothingChanged() throws {
        let store = makeStore()
        let profile = Profile(
            name: "Hau", authMethod: .cliSync,
            organizationId: "org-1",
            subscriptionPlan: "Max 20x",
            subscriptionCreatedAt: Date(timeIntervalSince1970: 1_700_500_000),
            email: "h@x.com",
            accountUuid: "acc-1",
            displayName: "Hau",
            accountCreatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            organizationName: "Hau's Org",
            subscriptionStatus: "active",
            billingType: "stripe_subscription",
            hasExtraUsageEnabled: false
        )
        try store.add(profile)

        let changed = try store.apply(oauthProfile: makeFullResponse(), for: profile.id)
        XCTAssertFalse(changed, "every field matches — apply must return false")
    }

    func test_applyOAuthProfile_throwsIdentityMismatch_onOrgUuidConflict() throws {
        // Regression for Codex round 5: a non-nil stored organizationId
        // that differs from a non-nil response.orgUuid signals the
        // probe is reading another account's data. Refuse the ENTIRE
        // write rather than partially merging (which would mix org-A
        // identity with org-B plan/account/billing metadata).
        let store = makeStore()
        let profile = Profile(
            name: "Hau", authMethod: .cliSync,
            organizationId: "org-A",
            subscriptionPlan: "Max 20x",
            email: "h@x.com"
        )
        try store.add(profile)

        let response = OAuthProfileFetcher.Response(
            planLabel: "Team Premium", orgUuid: "org-B",
            subscriptionCreatedAt: nil, subscriptionActive: true,
            hasExtraUsage: nil, displayName: "Spy",
            email: "h@x.com",
            accountUuid: "acc-B", accountCreatedAt: nil,
            organizationName: "B Team",
            subscriptionStatus: "active", billingType: "stripe_subscription"
        )

        XCTAssertThrowsError(try store.apply(oauthProfile: response, for: profile.id)) { error in
            guard case ProfileStore.StoreError.identityMismatch = error else {
                XCTFail("expected identityMismatch, got \(error)")
                return
            }
        }
        // None of the fields should have been written.
        let stored = store.profiles.first(where: { $0.id == profile.id })!
        XCTAssertEqual(stored.subscriptionPlan, "Max 20x",
                       "stored plan must not be overwritten when identity rejects")
        XCTAssertNil(stored.accountUuid, "accountUuid must not be written")
        XCTAssertNil(stored.organizationName, "organizationName must not be written")
    }

    func test_applyOAuthProfile_throwsIdentityMismatch_onAccountUuidConflict() throws {
        let store = makeStore()
        let profile = Profile(
            name: "Hau", authMethod: .cliSync,
            email: "h@x.com",
            accountUuid: "acc-A"
        )
        try store.add(profile)

        let response = OAuthProfileFetcher.Response(
            planLabel: nil, orgUuid: nil, subscriptionCreatedAt: nil,
            subscriptionActive: false, hasExtraUsage: nil,
            displayName: nil, email: nil,
            accountUuid: "acc-B", accountCreatedAt: nil,
            organizationName: nil, subscriptionStatus: nil, billingType: nil
        )
        XCTAssertThrowsError(try store.apply(oauthProfile: response, for: profile.id)) { error in
            guard case ProfileStore.StoreError.identityMismatch = error else {
                XCTFail("expected identityMismatch, got \(error)")
                return
            }
        }
    }

    func test_applyOAuthProfile_throwsIdentityMismatch_onEmailConflict() throws {
        let store = makeStore()
        let profile = Profile(
            name: "Hau", authMethod: .cliSync,
            email: "a@example.com"
        )
        try store.add(profile)

        let response = OAuthProfileFetcher.Response(
            planLabel: nil, orgUuid: nil, subscriptionCreatedAt: nil,
            subscriptionActive: false, hasExtraUsage: nil,
            displayName: nil, email: "b@example.com",
            accountUuid: nil, accountCreatedAt: nil,
            organizationName: nil, subscriptionStatus: nil, billingType: nil
        )
        XCTAssertThrowsError(try store.apply(oauthProfile: response, for: profile.id)) { error in
            guard case ProfileStore.StoreError.identityMismatch = error else {
                XCTFail("expected identityMismatch, got \(error)")
                return
            }
        }
    }

    func test_applyOAuthProfile_allowsApply_whenStoredIdentityIsNil() throws {
        // Companion: when stored has no orgId/accountUuid/email, response
        // can fill them in freely (first-probe backfill).
        let store = makeStore()
        let profile = Profile(name: "Hau", authMethod: .cliSync)
        try store.add(profile)

        let response = OAuthProfileFetcher.Response(
            planLabel: "Max 20x", orgUuid: "org-new", subscriptionCreatedAt: nil,
            subscriptionActive: true, hasExtraUsage: nil,
            displayName: nil, email: "h@x.com",
            accountUuid: "acc-new", accountCreatedAt: nil,
            organizationName: nil, subscriptionStatus: "active", billingType: nil
        )
        let changed = try store.apply(oauthProfile: response, for: profile.id)
        XCTAssertTrue(changed)
        let stored = store.profiles.first(where: { $0.id == profile.id })!
        XCTAssertEqual(stored.organizationId, "org-new")
        XCTAssertEqual(stored.accountUuid, "acc-new")
        XCTAssertEqual(stored.subscriptionPlan, "Max 20x")
    }

    // MARK: - activateOnAppearance

    func test_activateOnAppearance_nilActive_activatesTarget() throws {
        let store = makeStore()
        try store.add(Profile(name: "A", authMethod: .cliSync,
                              providerID: .claude, email: "a@x.com", kind: .auto))
        let aId = store.profiles[0].id
        // add() auto-activates the first profile; clear it to reach the nil-active state.
        try store.clearActive()
        XCTAssertNil(store.activeProfileId)

        let did = store.activateOnAppearance(id: aId, provider: .claude)

        XCTAssertTrue(did)
        XCTAssertEqual(store.activeProfileId, aId,
                       "with nothing active, appearance takes focus")
    }

    func test_activateOnAppearance_differentProviderActive_doesNotSteal() throws {
        let store = makeStore()
        try store.add(Profile(name: "Claude", authMethod: .cliSync,
                              providerID: .claude, email: "c@x.com", kind: .auto))
        try store.add(Profile(name: "Antigravity", authMethod: .cliSync,
                              providerID: .antigravity, kind: .auto))
        let claudeId = store.profiles[0].id
        let agId = store.profiles[1].id
        try store.setActive(id: claudeId)

        let did = store.activateOnAppearance(id: agId, provider: .antigravity)

        XCTAssertFalse(did)
        XCTAssertEqual(store.activeProfileId, claudeId,
                       "a different provider's live selection is not stolen")
    }

    func test_activateOnAppearance_sameProviderDifferentAccount_steals() throws {
        let store = makeStore()
        try store.add(Profile(name: "A", authMethod: .cliSync,
                              providerID: .claude, email: "a@x.com", kind: .auto))
        try store.add(Profile(name: "B", authMethod: .cliSync,
                              providerID: .claude, email: "b@x.com", kind: .auto))
        let aId = store.profiles[0].id
        let bId = store.profiles[1].id
        try store.setActive(id: aId)

        let did = store.activateOnAppearance(id: bId, provider: .claude)

        XCTAssertTrue(did)
        XCTAssertEqual(store.activeProfileId, bId,
                       "same provider, different account → CLI switched → follow it")
    }

    func test_activateOnAppearance_sameAccountAlreadyActive_isNoOpSuccess() throws {
        let store = makeStore()
        try store.add(Profile(name: "A", authMethod: .cliSync,
                              providerID: .claude, email: "a@x.com", kind: .auto))
        let aId = store.profiles[0].id
        try store.setActive(id: aId)

        let did = store.activateOnAppearance(id: aId, provider: .claude)

        XCTAssertTrue(did)
        XCTAssertEqual(store.activeProfileId, aId)
    }

    func test_activateOnAppearance_unknownId_returnsFalse() throws {
        let store = makeStore()
        let did = store.activateOnAppearance(id: UUID(), provider: .claude)
        XCTAssertFalse(did)
        XCTAssertNil(store.activeProfileId)
    }

    func test_applyOAuthProfile_rollsBackInMemoryState_whenSaveThrows() throws {
        // Regression for Codex round 6: a failed save() must NOT leave the
        // in-memory profiles array holding values that never reached disk.
        // We force save() to throw by making the parent directory read-only
        // after the initial add() so the atomic write is rejected by the OS.
        // (Removing the directory is insufficient: save() calls createDirectory
        // with withIntermediateDirectories:true which would recreate it.)
        let parentDir = temp.url.appendingPathComponent("savefail-\(UUID().uuidString)",
                                                        isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let profilesFile = parentDir.appendingPathComponent("profiles.json")

        let keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let store = ProfileStore(
            profilesFile: profilesFile,
            keychain: keychain,
            profileDirectoryProvider: { id in
                self.temp.url.appendingPathComponent(id.uuidString)
            }
        )

        let original = Profile(
            name: "Hau", authMethod: .cliSync,
            subscriptionPlan: "Max", email: "h@x.com"
        )
        try store.add(original)
        XCTAssertEqual(store.profiles.first?.subscriptionPlan, "Max")

        // Lock the parent directory read-only (r-xr-xr-x) so the atomic
        // write cannot replace the existing profiles.json.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o555))],
            ofItemAtPath: parentDir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: parentDir.path
            )
        }

        let response = OAuthProfileFetcher.Response(
            planLabel: "Max 20x", orgUuid: nil, subscriptionCreatedAt: nil,
            subscriptionActive: true, hasExtraUsage: nil,
            displayName: nil, email: nil,
            accountUuid: nil, accountCreatedAt: nil, organizationName: nil,
            subscriptionStatus: nil, billingType: nil
        )

        XCTAssertThrowsError(try store.apply(oauthProfile: response, for: original.id))

        // The in-memory array must be back to the pre-apply state since
        // the save failed. Otherwise the session would render "Max 20x"
        // while the on-disk file still says "Max".
        XCTAssertEqual(store.profiles.first?.subscriptionPlan, "Max",
                       "in-memory profile must roll back when save throws")
    }
}
