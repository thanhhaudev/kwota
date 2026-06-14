//
//  AutoProfileCoordinatorTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class AutoProfileCoordinatorTests: XCTestCase {
    private var temp: TempDirectory!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

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

    /// Builds a coordinator with hermetic keychain dependencies by default, so
    /// tests never touch the real macOS Keychain (which prompts for access).
    /// Call sites that pass `keychain:`/`credentialReader:` explicitly override
    /// these defaults, preserving their existing behavior.
    private func makeCoordinator(
        watcher: any CLIAccountWatching,
        profileStore: ProfileStore,
        keychain: KeychainCredentialStore? = nil,
        credentialReader: (any CLICredentialReading)? = nil,
        profileFetcher: any OAuthProfileFetching = OAuthProfileFetcher(),
        clock: @escaping () -> Date = { Date() },
        alwaysAllowRefresh: Bool = false
    ) -> AutoProfileCoordinator {
        AutoProfileCoordinator(
            watcher: watcher,
            profileStore: profileStore,
            keychain: keychain ?? KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())"),
            credentialReader: credentialReader ?? CLICredentialReader(
                credentialsFile: URL(fileURLWithPath: "/nonexistent"),
                keychainProbe: { nil }
            ),
            profileFetcher: profileFetcher,
            clock: clock,
            alwaysAllowRefresh: alwaysAllowRefresh
        )
    }

    // MARK: - identity handling

    func test_nilIdentity_clearsActiveProfile() throws {
        let store = makeStore()
        try store.add(Profile(name: "A", authMethod: .cliSync,
                              organizationId: "o", email: "a@x.com",
                              kind: .auto))
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(nil)
        XCTAssertNil(store.activeProfileId)
    }

    func test_unknownIdentity_createsAutoProfile_withBoundary() {
        let store = makeStore()
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "new@x.com", orgId: "org-new",
                                  credentialFingerprint: "ff"))
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].email, "new@x.com")
        XCTAssertEqual(store.profiles[0].organizationId, "org-new")
        XCTAssertEqual(store.profiles[0].kind, .auto)
        XCTAssertEqual(store.profiles[0].ownershipBoundary, t0)
        XCTAssertEqual(store.activeProfileId, store.profiles[0].id)
    }

    func test_matchingIdentity_activatesExistingProfile_preservesBoundary() throws {
        let store = makeStore()
        let oldBoundary = t0.addingTimeInterval(-100)
        try store.add(Profile(name: "A", authMethod: .cliSync,
                              organizationId: "org-a", email: "a@x.com",
                              kind: .auto,
                              ownershipBoundary: oldBoundary))
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-a",
                                  credentialFingerprint: "ff"))
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.activeProfileId, store.profiles[0].id)
        XCTAssertEqual(store.profiles[0].ownershipBoundary, oldBoundary,
                       "existing boundary preserved on activate")
    }

    func test_matchingArchived_promotesToAuto() throws {
        let store = makeStore()
        try store.add(Profile(name: "A", authMethod: .cliSync,
                              organizationId: "org-a", email: "a@x.com",
                              kind: .archived,
                              ownershipBoundary: t0.addingTimeInterval(-100)))
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-a",
                                  credentialFingerprint: "ff"))
        XCTAssertEqual(store.profiles[0].kind, .auto)
    }

    func test_identityRepeat_noOp() {
        let store = makeStore()
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        let id = CLIIdentity(email: "a@x.com", orgId: "org-a",
                              credentialFingerprint: "ff")
        watcher.emit(id)
        watcher.emit(id)
        XCTAssertEqual(store.profiles.count, 1, "duplicate emit must not duplicate profile")
    }

    // MARK: - guardRefresh

    func test_guardRefresh_allowsMatchingAutoProfile() {
        let store = makeStore()
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-a",
                                  credentialFingerprint: "ff"))
        let active = store.profiles[0]
        XCTAssertTrue(coord.guardRefresh(profile: active))
    }

    func test_guardRefresh_blocksArchivedProfile() throws {
        let store = makeStore()
        var archived = Profile(name: "Old", authMethod: .sessionKey,
                                organizationId: "o", email: "old@x.com")
        archived.kind = .archived
        try store.add(archived)
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        XCTAssertFalse(coord.guardRefresh(profile: archived))
    }

    func test_guardRefresh_blocksMismatchedAutoProfile() throws {
        let store = makeStore()
        var p = Profile(name: "P", authMethod: .cliSync,
                        organizationId: "org-a", email: "a@x.com")
        p.kind = .auto
        try store.add(p)
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "different@x.com", orgId: "org-b",
                                  credentialFingerprint: "ff"))
        XCTAssertFalse(coord.guardRefresh(profile: p),
                       "profile email no longer matches watcher.current")
    }

    func test_guardRefresh_allowsWhenWatcherOrgIdIsNil_andEmailMatches() throws {
        // Migrated profile from wizard era keeps its organizationId; the
        // watcher cannot read orgId from ~/.claude.json so emits nil. Email
        // match alone must be enough or every migrated profile would be
        // stuck on the loading spinner.
        let store = makeStore()
        var p = Profile(name: "P", authMethod: .cliSync,
                        organizationId: "org-a", email: "a@x.com")
        p.kind = .auto
        try store.add(p)
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: nil,
                                  credentialFingerprint: "ff"))
        XCTAssertTrue(coord.guardRefresh(profile: p),
                      "watcher cannot supply orgId; email match alone must pass")
    }

    func test_guardRefresh_blocksWhenWatcherOrgIdMismatches_strictly() throws {
        // Once /me-based orgId resolution lands and the watcher reports a
        // non-nil orgId, the strict check kicks in.
        let store = makeStore()
        var p = Profile(name: "P", authMethod: .cliSync,
                        organizationId: "org-a", email: "a@x.com")
        p.kind = .auto
        try store.add(p)
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-b",
                                  credentialFingerprint: "ff"))
        XCTAssertFalse(coord.guardRefresh(profile: p),
                       "non-nil watcher orgId mismatch must still block")
    }

    func test_guardRefresh_blocksWhenWatcherIsNil() throws {
        let store = makeStore()
        var p = Profile(name: "P", authMethod: .cliSync,
                        organizationId: "org-a", email: "a@x.com")
        p.kind = .auto
        try store.add(p)
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(nil)
        XCTAssertFalse(coord.guardRefresh(profile: p))
    }

    func test_emailFallback_reusesExistingAutoProfile_whenOrgIdNil() throws {
        let store = makeStore()
        let existing = Profile(name: "A", authMethod: .cliSync,
                               organizationId: nil, email: "a@x.com",
                               kind: .auto,
                               ownershipBoundary: t0.addingTimeInterval(-500))
        try store.add(existing)
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: nil,
                                  credentialFingerprint: "ff"))
        XCTAssertEqual(store.profiles.count, 1,
                       "no duplicate created when email matches existing auto profile")
        XCTAssertEqual(store.activeProfileId, existing.id)
        XCTAssertEqual(store.profiles[0].ownershipBoundary, existing.ownershipBoundary,
                       "boundary preserved on email-fallback activation")
    }

    func test_emailFallback_archivedProfile_isReused() throws {
        // Fix 1: the archived-email fallback now reuses an archived profile
        // instead of creating a duplicate. The archived profile is promoted
        // back to .auto so history and ownership boundary are preserved.
        let store = makeStore()
        let archived = Profile(name: "Old", authMethod: .sessionKey,
                               organizationId: nil, email: "old@x.com",
                               kind: .archived,
                               ownershipBoundary: t0.addingTimeInterval(-200))
        try store.add(archived)
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "old@x.com", orgId: nil,
                                  credentialFingerprint: "ff"))
        XCTAssertEqual(store.profiles.count, 1,
                       "archived-email fallback must reuse the archived profile, not create a duplicate")
        XCTAssertEqual(store.profiles[0].kind, .auto,
                       "reused archived profile must be promoted to .auto")
        XCTAssertEqual(store.profiles[0].ownershipBoundary, archived.ownershipBoundary,
                       "original boundary preserved across archived-to-auto promotion")
    }

    func test_compositeMatchTakesPrecedenceOverEmailFallback() throws {
        let store = makeStore()
        // Two profiles share email; one has the matching orgId.
        let pA = Profile(name: "A", authMethod: .cliSync,
                         organizationId: "org-a", email: "a@x.com",
                         kind: .auto)
        let pB = Profile(name: "B", authMethod: .cliSync,
                         organizationId: nil, email: "a@x.com",
                         kind: .auto)
        try store.add(pA)
        try store.add(pB)
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        // Identity has full orgId — composite match must win even when an
        // email-only match also exists.
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-a",
                                  credentialFingerprint: "ff"))
        XCTAssertEqual(store.activeProfileId, pA.id,
                       "composite match takes precedence over email fallback")
    }

    // MARK: - Sign-out then sign-in same account (Fix 1 regression)

    func test_signOutThenSignIn_sameAccount_reusesArchivedProfile() throws {
        let store = makeStore()
        let originalBoundary = t0.addingTimeInterval(-500)
        try store.add(Profile(name: "A", authMethod: .cliSync,
                              providerID: .claude, organizationId: nil,
                              email: "a@x.com", kind: .auto,
                              ownershipBoundary: originalBoundary))
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher, profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()

        // Step 1: nil identity (sign-out) demotes the active profile.
        watcher.emit(nil)
        XCTAssertEqual(store.profiles[0].kind, .archived,
                       "sign-out must archive the active auto profile")
        XCTAssertNil(store.activeProfileId)

        // Step 2: same-account sign-in. Without the archived-fallback this
        // would create a duplicate; with it the original profile is reused.
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: nil,
                                  credentialFingerprint: "ff"))
        XCTAssertEqual(store.profiles.count, 1,
                       "must not create a duplicate when archived profile exists for same email")
        XCTAssertEqual(store.profiles[0].kind, .auto,
                       "archived match must be promoted back to auto")
        XCTAssertEqual(store.profiles[0].ownershipBoundary, originalBoundary,
                       "original boundary preserved across the cycle")
        XCTAssertEqual(store.activeProfileId, store.profiles[0].id)
    }

    func test_emailAwaitingOrg_adoptsLegacyAutoProfileWhenIdentityProvidesOrgId() throws {
        // Legacy auto profile from the nil-orgId era. When /me-resolution
        // ships and the watcher starts emitting orgId, the legacy profile
        // must be adopted (orgId written through) instead of replaced.
        let store = makeStore()
        let originalBoundary = t0.addingTimeInterval(-300)
        let legacy = Profile(name: "Legacy", authMethod: .cliSync,
                             providerID: .claude, organizationId: nil,
                             email: "a@x.com", kind: .auto,
                             ownershipBoundary: originalBoundary)
        try store.add(legacy)
        let originalId = legacy.id

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher, profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-newly-learned",
                                  credentialFingerprint: "ff"))

        XCTAssertEqual(store.profiles.count, 1,
                       "legacy nil-org profile must be adopted, not duplicated")
        let adopted = store.profiles[0]
        XCTAssertEqual(adopted.id, originalId, "stable id across the migration")
        XCTAssertEqual(adopted.organizationId, "org-newly-learned",
                       "freshly-learned orgId must be written through")
        XCTAssertEqual(adopted.ownershipBoundary, originalBoundary,
                       "boundary preserved")
    }

    func test_emailAwaitingOrg_adoptsLegacyArchivedProfileAndPromotes() throws {
        // Same scenario but with an archived profile (e.g. user signed out
        // before /me landed, then signed back in afterward).
        let store = makeStore()
        var legacy = Profile(name: "Legacy", authMethod: .cliSync,
                             providerID: .claude, organizationId: nil,
                             email: "a@x.com",
                             kind: .archived,
                             ownershipBoundary: t0.addingTimeInterval(-300))
        legacy.kind = .archived
        try store.add(legacy)
        let originalId = legacy.id

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher, profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-newly-learned",
                                  credentialFingerprint: "ff"))

        XCTAssertEqual(store.profiles.count, 1,
                       "legacy archived nil-org profile must be adopted, not duplicated")
        let adopted = store.profiles[0]
        XCTAssertEqual(adopted.id, originalId)
        XCTAssertEqual(adopted.kind, .auto, "archived adoption must promote to auto")
        XCTAssertEqual(adopted.organizationId, "org-newly-learned",
                       "orgId migrated through")
    }

    func test_emailAwaitingOrg_doesNotMatchProfileWithStoredOrgId() throws {
        // A profile that already has a different stored orgId must NOT
        // be picked up by the awaiting-org migration step — the strict
        // composite path is responsible for the real-vs-real comparison,
        // and a mismatch there means a genuinely different account.
        let store = makeStore()
        try store.add(Profile(name: "OrgA", authMethod: .cliSync,
                              providerID: .claude, organizationId: "org-a",
                              email: "a@x.com", kind: .archived))

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher, profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-b",
                                  credentialFingerprint: "ff"))

        XCTAssertEqual(store.profiles.count, 2,
                       "differing-org archived profile must remain untouched; new profile is created")
        let activated = store.profiles.first { $0.id == store.activeProfileId }
        XCTAssertEqual(activated?.organizationId, "org-b")
    }

    func test_emailAwaitingOrg_skipsSessionKeyLegacyProfile() throws {
        // A user with a legacy wizard-era sessionKey profile for the same
        // email must not have the new CLI orgId + credential silently
        // attached to that profile. Adoption must be reserved for cliSync
        // profiles — sessionKey identity is paste-flow and pre-dates
        // auto-detect.
        let store = makeStore()
        try store.add(Profile(name: "Pasted", authMethod: .sessionKey,
                              providerID: .claude, organizationId: nil,
                              email: "a@x.com", kind: .archived))

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher, profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-new",
                                  credentialFingerprint: "ff"))

        XCTAssertEqual(store.profiles.count, 2,
                       "sessionKey legacy profile must remain untouched; new cliSync profile created")
        let sessionKey = store.profiles.first { $0.authMethod == .sessionKey }
        XCTAssertEqual(sessionKey?.organizationId, nil,
                       "sessionKey profile's nil orgId must not be overwritten")
        XCTAssertEqual(sessionKey?.kind, .archived,
                       "sessionKey profile must not be promoted to auto")
        let activated = store.profiles.first { $0.id == store.activeProfileId }
        XCTAssertEqual(activated?.authMethod, .cliSync)
        XCTAssertEqual(activated?.organizationId, "org-new")
    }

    func test_emailAwaitingOrg_refusesAdoption_whenAutoAndArchivedNilOrgSameEmailCoexist() throws {
        // Multi-workspace same-email scenario: profile A is auto for org-A
        // (nil-org era), profile B is archived from org-B (also nil-org).
        // Both have email a@x.com. /me resolves to org-B. Preferring the
        // auto here would silently overwrite A's org-A history with
        // org-B's identity — data corruption.
        //
        // Correct behavior: refuse adoption, create a new org-B-bound
        // profile, let the user clean up A and B with full org context
        // visible.
        let store = makeStore()
        let liveAuto = Profile(name: "A", authMethod: .cliSync,
                               providerID: .claude, organizationId: nil,
                               email: "a@x.com", kind: .auto)
        try store.add(liveAuto)
        let archivedOtherOrg = Profile(name: "B", authMethod: .cliSync,
                                        providerID: .claude, organizationId: nil,
                                        email: "a@x.com", kind: .archived)
        try store.add(archivedOtherOrg)
        let aId = liveAuto.id
        let bId = archivedOtherOrg.id

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher, profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-b",
                                  credentialFingerprint: "ff"))

        XCTAssertEqual(store.profiles.count, 3,
                       "ambiguous nil-org candidates must not be mutated; create new instead")
        // A and B both unchanged.
        let aAfter = store.profiles.first { $0.id == aId }
        XCTAssertEqual(aAfter?.organizationId, nil,
                       "live auto must not have org-b silently written")
        // A was demoted by the single-auto invariant when the new profile activated.
        // That's still correct — the new profile is org-b's live binding.
        let bAfter = store.profiles.first { $0.id == bId }
        XCTAssertEqual(bAfter?.organizationId, nil,
                       "archived multi-workspace candidate must remain untouched")
        XCTAssertEqual(bAfter?.kind, .archived)
        // New profile carries org-b.
        let activated = store.profiles.first { $0.id == store.activeProfileId }
        XCTAssertEqual(activated?.organizationId, "org-b")
        XCTAssertNotEqual(activated?.id, aId)
        XCTAssertNotEqual(activated?.id, bId)
    }

    func test_emailAwaitingOrg_skipsWhenMultipleAutoCandidates() throws {
        // Two cliSync nil-org AUTO profiles is genuine ambiguity. Skip
        // adoption; create a new profile so the user resolves the
        // duplicate manually.
        let store = makeStore()
        try store.add(Profile(name: "Auto1", authMethod: .cliSync,
                              providerID: .claude, organizationId: nil,
                              email: "a@x.com", kind: .auto))
        try store.add(Profile(name: "Auto2", authMethod: .cliSync,
                              providerID: .claude, organizationId: nil,
                              email: "a@x.com", kind: .auto))

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher, profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-new",
                                  credentialFingerprint: "ff"))

        XCTAssertEqual(store.profiles.count, 3,
                       "two auto candidates is true ambiguity; falls through to create")
        let activated = store.profiles.first { $0.id == store.activeProfileId }
        XCTAssertEqual(activated?.organizationId, "org-new")
        let nilOrgProfiles = store.profiles.filter { $0.organizationId == nil }
        XCTAssertEqual(nilOrgProfiles.count, 2,
                       "neither ambiguous auto was mutated")
    }

    func test_emailAwaitingOrg_skipsWhenZeroAutoAndMultipleArchived() throws {
        // No auto candidate but two archived → still ambiguous, refuse.
        let store = makeStore()
        try store.add(Profile(name: "Old1", authMethod: .cliSync,
                              providerID: .claude, organizationId: nil,
                              email: "a@x.com", kind: .archived))
        try store.add(Profile(name: "Old2", authMethod: .cliSync,
                              providerID: .claude, organizationId: nil,
                              email: "a@x.com", kind: .archived))

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher, profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-new",
                                  credentialFingerprint: "ff"))

        XCTAssertEqual(store.profiles.count, 3,
                       "two archived candidates with no auto is still ambiguous; falls through")
    }

    func test_archivedFallback_skipsWhenIdentityHasOrgId() throws {
        // Pre-existing archived profile (e.g. team workspace org-A the user
        // used previously). Watcher now emits a different identity from
        // org-B with the same email. The archived org-A profile must NOT
        // be resurrected — the cascade must fall through to create a new
        // profile bound to org-B's identity.
        let store = makeStore()
        var archivedA = Profile(name: "OrgA", authMethod: .cliSync,
                                 providerID: .claude, organizationId: "org-a",
                                 email: "a@x.com", kind: .archived,
                                 ownershipBoundary: t0.addingTimeInterval(-500))
        archivedA.kind = .archived
        try store.add(archivedA)
        let originalArchivedId = archivedA.id

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher, profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-b",
                                  credentialFingerprint: "ff"))

        XCTAssertEqual(store.profiles.count, 2,
                       "non-nil orgId mismatch must create a new profile, not resurrect the archived one")
        let archivedAfter = store.profiles.first { $0.id == originalArchivedId }
        XCTAssertEqual(archivedAfter?.kind, .archived,
                       "the org-A archived profile must remain archived")
        let activated = store.profiles.first { $0.id == store.activeProfileId }
        XCTAssertEqual(activated?.organizationId, "org-b",
                       "the new active profile must carry org-b's identity")
    }

    // MARK: - Keychain seeding (Fix 1)

    func test_create_seedsKeychain_andWritesMetadata() {
        let store = makeStore()
        let keychainService = "com.thanhhaudev.Kwota.test.\(UUID())"
        let keychain = KeychainCredentialStore(service: keychainService)
        let credReader = CLICredentialReader(
            credentialsFile: URL(fileURLWithPath: "/nonexistent"),
            keychainProbe: {
                let payload = """
                {"claudeAiOauth":{"accessToken":"seed-tok","refreshToken":"r","expiresAt":99999999999}}
                """
                return Data(payload.utf8)
            }
        )
        let watcher = FakeWatcher()
        let coord = makeCoordinator(
            watcher: watcher,
            profileStore: store,
            keychain: keychain,
            credentialReader: credReader,
            profileFetcher: AlwaysNilOAuthProfileFetcher(),
            clock: { self.t0 }
        )
        coord.start()
        watcher.emit(CLIIdentity(
            email: "new@x.com", orgId: nil, credentialFingerprint: "ff",
            seatTier: "max_5x", organizationType: nil
        ))
        let profile = store.profiles.first!
        // Keychain should have been seeded.
        let stored = try? keychain.read(for: profile.id)
        XCTAssertNotNil(stored, "coordinator must seed keychain on profile create")
        // Plan should be derived from seatTier.
        XCTAssertEqual(profile.subscriptionPlan, "Max 5x")
        // Name uses email when displayName is nil.
        XCTAssertEqual(profile.name, "new@x.com")
    }

    func test_match_seedsKeychain_whenStoreHadNoCredential() throws {
        let store = makeStore()
        let keychainService = "com.thanhhaudev.Kwota.test.\(UUID())"
        let keychain = KeychainCredentialStore(service: keychainService)
        // Pre-existing profile with no keychain entry.
        let existing = Profile(name: "A", authMethod: .cliSync,
                               organizationId: nil, email: "a@x.com",
                               kind: .auto,
                               ownershipBoundary: t0)
        try store.add(existing)
        let credReader = CLICredentialReader(
            credentialsFile: URL(fileURLWithPath: "/nonexistent"),
            keychainProbe: {
                let payload = """
                {"claudeAiOauth":{"accessToken":"heal-tok","refreshToken":"r","expiresAt":99999999999}}
                """
                return Data(payload.utf8)
            }
        )
        let watcher = FakeWatcher()
        let coord = makeCoordinator(
            watcher: watcher,
            profileStore: store,
            keychain: keychain,
            credentialReader: credReader,
            profileFetcher: AlwaysNilOAuthProfileFetcher(),
            clock: { self.t0 }
        )
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: nil, credentialFingerprint: "ff"))
        // Keychain should now have an entry for the existing profile.
        let stored = try? keychain.read(for: existing.id)
        XCTAssertNotNil(stored, "coordinator must retroactively seed keychain for matched profile missing credential")
    }

    func test_match_updatesProfileMetadata_whenIdentityHasNewer() throws {
        let store = makeStore()
        // Profile with stale plan.
        let stale = Profile(name: "Old Name", authMethod: .cliSync,
                            organizationId: nil,
                            subscriptionPlan: "Pro",
                            email: "a@x.com",
                            kind: .auto,
                            ownershipBoundary: t0)
        try store.add(stale)
        let watcher = FakeWatcher()
        let coord = makeCoordinator(
            watcher: watcher,
            profileStore: store,
            profileFetcher: AlwaysNilOAuthProfileFetcher(),
            clock: { self.t0 }
        )
        coord.start()
        watcher.emit(CLIIdentity(
            email: "a@x.com", orgId: nil, credentialFingerprint: "ff",
            seatTier: "max_5x", organizationType: nil, displayName: "New Name"
        ))
        let updated = store.profiles.first!
        XCTAssertEqual(updated.subscriptionPlan, "Max 5x", "stale plan should be updated to Max 5x")
        XCTAssertEqual(updated.name, "New Name", "display name should be updated from identity")
    }

    // MARK: - Credential rotation (Fix 2)

    func test_match_overwritesStoredCredential_whenCLIRotated() throws {
        // Existing profile has a stale token T1 in Kwota's keychain. CLI now
        // reports T2 (same account, re-login or rotation). The stored token is
        // expired so the guard falls through, the coordinator imports the
        // rotated CLI token, and the store must end up holding T2.
        let store = makeStore()
        let kwotaKeychain = KeychainCredentialStore(
            service: "com.thanhhaudev.Kwota.test.\(UUID())"
        )
        let profile = Profile(name: "A", authMethod: .cliSync,
                              providerID: .claude, organizationId: nil,
                              email: "a@x.com", kind: .auto)
        try store.add(profile)
        let oldToken = Credential.cliToken(
            accessToken: "T1", refreshToken: "r1",
            expiresAt: Date(timeIntervalSince1970: 0)   // stale → guard falls through, must re-import
        )
        try kwotaKeychain.write(oldToken, for: profile.id)

        // Fake reader returns T2.
        let newToken = Credential.cliToken(
            accessToken: "T2", refreshToken: "r2",
            expiresAt: .distantFuture
        )
        let reader = StubCredentialReader(stub: newToken)

        let watcher = FakeWatcher()
        let coord = makeCoordinator(
            watcher: watcher,
            profileStore: store,
            keychain: kwotaKeychain,
            credentialReader: reader,
            profileFetcher: AlwaysNilOAuthProfileFetcher(),
            clock: { self.t0 }
        )
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: nil,
                                  credentialFingerprint: "ff-new"))

        let restored = try kwotaKeychain.read(for: profile.id)
        if case .cliToken(let access, _, _) = restored {
            XCTAssertEqual(access, "T2", "stored credential must rotate to current CLI token")
        } else {
            XCTFail("expected cliToken in keychain, got \(String(describing: restored))")
        }
    }

    func test_match_keepsStoredCredential_whenCLITokenUnchanged() throws {
        // No-op rotation: stored T1 is expired (guard falls through to the
        // read), reader also returns T1, accessTokensMatch → no write. Store keeps T1.
        let store = makeStore()
        let kwotaKeychain = KeychainCredentialStore(
            service: "com.thanhhaudev.Kwota.test.\(UUID())"
        )
        let profile = Profile(name: "A", authMethod: .cliSync,
                              providerID: .claude, organizationId: nil,
                              email: "a@x.com", kind: .auto)
        try store.add(profile)
        let token = Credential.cliToken(
            accessToken: "T1", refreshToken: "r1",
            expiresAt: Date(timeIntervalSince1970: 0)   // stale → guard falls through, reader matches, no write
        )
        try kwotaKeychain.write(token, for: profile.id)

        let reader = StubCredentialReader(stub: token)
        let watcher = FakeWatcher()
        let coord = makeCoordinator(
            watcher: watcher,
            profileStore: store,
            keychain: kwotaKeychain,
            credentialReader: reader,
            profileFetcher: AlwaysNilOAuthProfileFetcher(),
            clock: { self.t0 }
        )
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: nil,
                                  credentialFingerprint: "ff"))

        let restored = try kwotaKeychain.read(for: profile.id)
        if case .cliToken(let access, _, _) = restored {
            XCTAssertEqual(access, "T1")
        } else {
            XCTFail("expected cliToken")
        }
    }

    // MARK: - Skip CLI Keychain read when stored credential is valid

    func test_seedOrUpdateKeychain_skipsCLIRead_whenStoredCredentialStillValid() throws {
        // Simulates the startup baseline emit: Kwota already holds a non-expired
        // token, so the coordinator must NOT read Claude Code's Keychain (no prompt).
        let store = makeStore()
        let kwotaKeychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let profile = Profile(name: "A", authMethod: .cliSync,
                              providerID: .claude, organizationId: nil,
                              email: "a@x.com", kind: .auto, ownershipBoundary: t0)
        try store.add(profile)
        let storedToken = Credential.cliToken(accessToken: "stored",
                                              refreshToken: "r",
                                              expiresAt: .distantFuture)
        try kwotaKeychain.write(storedToken, for: profile.id)

        var readerCallCount = 0
        let reader = CLICredentialReader(
            credentialsFile: URL(fileURLWithPath: "/nonexistent"),
            keychainProbe: { readerCallCount += 1; return nil }
        )
        let watcher = FakeWatcher()
        let coord = makeCoordinator(
            watcher: watcher,
            profileStore: store,
            keychain: kwotaKeychain,
            credentialReader: reader,
            profileFetcher: AlwaysNilOAuthProfileFetcher(),
            clock: { self.t0 }
        )
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: nil,
                                  credentialFingerprint: "ff"))

        XCTAssertEqual(readerCallCount, 0,
            "a valid stored credential must short-circuit before reading Claude Code's Keychain — including the startup baseline emit")
    }

    // MARK: - Single-auto invariant (Fix 4)

    func test_singleAutoInvariant_demotesOtherAutos_onActivate() throws {
        let store = makeStore()
        let p1 = Profile(name: "P1", authMethod: .cliSync,
                         organizationId: nil, email: "a@x.com",
                         kind: .auto, ownershipBoundary: t0)
        let p2 = Profile(name: "P2", authMethod: .cliSync,
                         organizationId: nil, email: "b@x.com",
                         kind: .auto, ownershipBoundary: t0)
        try store.add(p1)
        try store.add(p2)
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        // Emit identity for p1 — p2 should be demoted.
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: nil, credentialFingerprint: "ff"))
        let kinds = Dictionary(uniqueKeysWithValues: store.profiles.map { ($0.id, $0.kind) })
        XCTAssertEqual(kinds[p1.id], .auto, "matched profile stays .auto")
        XCTAssertEqual(kinds[p2.id], .archived, "other auto profile must be demoted to .archived")
    }

    func test_nilIdentity_demotesPreviouslyActiveAutoProfile() throws {
        let store = makeStore()
        let p = Profile(name: "P", authMethod: .cliSync,
                        organizationId: nil, email: "a@x.com",
                        kind: .auto, ownershipBoundary: t0)
        try store.add(p)
        try store.setActive(id: p.id)
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(nil)
        let demoted = store.profiles.first { $0.id == p.id }!
        XCTAssertEqual(demoted.kind, .archived,
                       "previously-active .auto profile must be archived when CLI signs out")
        XCTAssertNil(store.activeProfileId, "active profile cleared on sign-out")
    }

    // MARK: - Guard A: never clobber stored plan with nil

    func test_handle_existingMatch_doesNotClobberPlan_whenIdentityHasNilPlan() throws {
        // Reproduces the Max→Free regression: CLI's oauthAccount now writes
        // seatTier=null for paid Max users, so identity.seatTier is nil. The
        // coordinator must preserve the previously-stored plan instead of
        // overwriting it with the freshly-derived nil.
        let store = makeStore()
        try store.add(Profile(name: "Hau", authMethod: .cliSync,
                              providerID: .claude, organizationId: nil,
                              subscriptionPlan: "Max",
                              email: "h@x.com", kind: .auto,
                              ownershipBoundary: t0))
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(
            email: "h@x.com", orgId: nil, credentialFingerprint: "ff",
            seatTier: nil, organizationType: nil
        ))
        XCTAssertEqual(store.profiles[0].subscriptionPlan, "Max",
                       "stored plan must not be clobbered by a nil expectedPlan")
    }

    func test_handle_existingMatch_doesNotClobberSubscriptionCreatedAt_whenIdentityNil() throws {
        let stored = t0.addingTimeInterval(-86_400 * 30)
        let store = makeStore()
        try store.add(Profile(name: "Hau", authMethod: .cliSync,
                              providerID: .claude, organizationId: nil,
                              subscriptionPlan: "Max",
                              subscriptionCreatedAt: stored,
                              email: "h@x.com", kind: .auto,
                              ownershipBoundary: t0))
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(
            email: "h@x.com", orgId: nil, credentialFingerprint: "ff",
            seatTier: nil, organizationType: nil,
            subscriptionCreatedAt: nil
        ))
        XCTAssertEqual(store.profiles[0].subscriptionCreatedAt, stored,
                       "stored subscriptionCreatedAt must not be clobbered by a nil identity value")
    }

    // MARK: - probePlanFromProfile

    /// Helper: spin the main run loop until the fetcher stub records the
    /// expected call count or the deadline elapses. The probe is dispatched
    /// from a fire-and-forget `Task { @MainActor }`, so the assert that
    /// follows `watcher.emit` cannot synchronously observe its result.
    private func waitUntilFetcherCalled(_ stub: StubOAuthProfileFetcher,
                                        count: Int,
                                        timeout: TimeInterval = 1.0,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while stub.callCount < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
        XCTAssertEqual(stub.callCount, count,
                       "fetcher should have been called \(count) time(s)",
                       file: file, line: line)
    }

    private func waitUntilStoredPlanEquals(_ store: ProfileStore,
                                           profileId: UUID,
                                           expected: String?,
                                           timeout: TimeInterval = 1.0,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while store.profiles.first(where: { $0.id == profileId })?.subscriptionPlan != expected,
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let actual = store.profiles.first(where: { $0.id == profileId })?.subscriptionPlan
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func test_probe_updatesStoredPlan_whenFetcherReturnsRicherLabel() async throws {
        let store = makeStore()
        let kc = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        try store.add(Profile(name: "Hau", authMethod: .cliSync,
                              providerID: .claude, organizationId: nil,
                              subscriptionPlan: "Max",
                              email: "h@x.com", kind: .auto,
                              ownershipBoundary: t0))
        let profileId = store.profiles[0].id
        try kc.write(.cliToken(accessToken: "T", refreshToken: "r",
                               expiresAt: .distantFuture), for: profileId)
        let stub = StubOAuthProfileFetcher()
        stub.outcome = .success(.init(
            planLabel: "Max 20x", orgUuid: nil, subscriptionCreatedAt: nil,
            subscriptionActive: true, hasExtraUsage: false,
            displayName: nil, email: nil,
            accountUuid: nil, accountCreatedAt: nil,
            organizationName: nil, subscriptionStatus: nil, billingType: nil
        ))
        let watcher = FakeWatcher()
        let coord = makeCoordinator(
            watcher: watcher, profileStore: store, keychain: kc,
            credentialReader: StubCredentialReader(stub: .cliToken(
                accessToken: "T", refreshToken: "r", expiresAt: .distantFuture
            )),
            profileFetcher: stub,
            clock: { self.t0 }
        )
        coord.start()
        watcher.emit(CLIIdentity(email: "h@x.com", orgId: nil,
                                  credentialFingerprint: "ff"))
        await waitUntilStoredPlanEquals(store, profileId: profileId, expected: "Max 20x")
    }

    func test_probe_keepsStoredPlan_whenFetcherReturnsNilLabel() async throws {
        let store = makeStore()
        let kc = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        try store.add(Profile(name: "Hau", authMethod: .cliSync,
                              providerID: .claude, organizationId: nil,
                              subscriptionPlan: "Max",
                              email: "h@x.com", kind: .auto,
                              ownershipBoundary: t0))
        let profileId = store.profiles[0].id
        try kc.write(.cliToken(accessToken: "T", refreshToken: "r",
                               expiresAt: .distantFuture), for: profileId)
        let stub = StubOAuthProfileFetcher()
        // Default outcome is .success with planLabel: nil.
        let watcher = FakeWatcher()
        let coord = makeCoordinator(
            watcher: watcher, profileStore: store, keychain: kc,
            credentialReader: StubCredentialReader(stub: .cliToken(
                accessToken: "T", refreshToken: "r", expiresAt: .distantFuture
            )),
            profileFetcher: stub,
            clock: { self.t0 }
        )
        coord.start()
        watcher.emit(CLIIdentity(email: "h@x.com", orgId: nil,
                                  credentialFingerprint: "ff"))
        await waitUntilFetcherCalled(stub, count: 1)
        XCTAssertEqual(store.profiles[0].subscriptionPlan, "Max",
                       "nil planLabel from fetcher must not overwrite stored plan")
    }

    func test_probe_keepsStoredPlan_whenFetcherThrows() async throws {
        let store = makeStore()
        let kc = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        try store.add(Profile(name: "Hau", authMethod: .cliSync,
                              providerID: .claude, organizationId: nil,
                              subscriptionPlan: "Max",
                              email: "h@x.com", kind: .auto,
                              ownershipBoundary: t0))
        let profileId = store.profiles[0].id
        try kc.write(.cliToken(accessToken: "T", refreshToken: "r",
                               expiresAt: .distantFuture), for: profileId)
        let stub = StubOAuthProfileFetcher()
        stub.outcome = .failure(ClaudeAPIClient.APIError.unauthorized)
        let watcher = FakeWatcher()
        let coord = makeCoordinator(
            watcher: watcher, profileStore: store, keychain: kc,
            credentialReader: StubCredentialReader(stub: .cliToken(
                accessToken: "T", refreshToken: "r", expiresAt: .distantFuture
            )),
            profileFetcher: stub,
            clock: { self.t0 }
        )
        coord.start()
        watcher.emit(CLIIdentity(email: "h@x.com", orgId: nil,
                                  credentialFingerprint: "ff"))
        await waitUntilFetcherCalled(stub, count: 1)
        XCTAssertEqual(store.profiles[0].subscriptionPlan, "Max",
                       "fetcher error must not clobber stored plan")
    }

    func test_probe_setsPlanOnNewProfile_whenSeatTierNil() async throws {
        let store = makeStore()
        let kc = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let credReader = CLICredentialReader(
            credentialsFile: URL(fileURLWithPath: "/nonexistent"),
            keychainProbe: {
                let payload = """
                {"claudeAiOauth":{"accessToken":"seed-tok","refreshToken":"r","expiresAt":99999999999}}
                """
                return Data(payload.utf8)
            }
        )
        let stub = StubOAuthProfileFetcher()
        stub.outcome = .success(.init(
            planLabel: "Max 20x", orgUuid: nil, subscriptionCreatedAt: nil,
            subscriptionActive: true, hasExtraUsage: false,
            displayName: nil, email: nil,
            accountUuid: nil, accountCreatedAt: nil,
            organizationName: nil, subscriptionStatus: nil, billingType: nil
        ))
        let watcher = FakeWatcher()
        let coord = makeCoordinator(
            watcher: watcher, profileStore: store, keychain: kc,
            credentialReader: credReader,
            profileFetcher: stub,
            clock: { self.t0 }
        )
        coord.start()
        watcher.emit(CLIIdentity(
            email: "new@x.com", orgId: nil, credentialFingerprint: "ff",
            seatTier: nil, organizationType: nil
        ))
        XCTAssertEqual(store.profiles.count, 1)
        let newId = store.profiles[0].id
        await waitUntilStoredPlanEquals(store, profileId: newId, expected: "Max 20x")
    }

    // MARK: - Cross-provider sign-out isolation

    func test_signOut_doesNotTouchCodexProfile_andDoesNotClearActive() throws {
        // Codex profile is active. Claude watcher emits nil.
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
        try store.setActive(id: codex.id)

        let watcher = FakeWatcher()
        let coord = makeCoordinator(
            watcher: watcher,
            profileStore: store,
            profileFetcher: AlwaysNilOAuthProfileFetcher(),
            alwaysAllowRefresh: true
        )
        coord.start()

        // Emit Claude sign-out.
        watcher.emit(nil)

        let storedCodex = store.profiles.first { $0.id == codex.id }
        XCTAssertEqual(storedCodex?.kind, .auto,
                       "Claude sign-out must not archive a Codex profile")
        XCTAssertEqual(store.activeProfileId, codex.id,
                       "Claude sign-out must leave the Codex profile active when it is the live one")
    }

    // MARK: - Multi-provider guard (C1 + C3)

    func test_guardRefresh_alwaysAllowsNonClaudeProvider() throws {
        let store = makeStore()
        let watcher = FakeWatcher()  // current is nil — Claude CLI not logged in
        let keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let coord = makeCoordinator(
            watcher: watcher,
            profileStore: store,
            keychain: keychain,
            credentialReader: StubCredentialReader(stub: .cliToken(
                accessToken: "t", refreshToken: "r", expiresAt: .distantFuture
            )),
            profileFetcher: AlwaysNilOAuthProfileFetcher(),
            clock: { self.t0 }
        )
        coord.start()
        var codex = Profile(
            name: "Codex",
            authMethod: .cliSync,
            providerID: .codex,
            email: "u@x.com",
            kind: .auto,
            ownershipBoundary: t0
        )
        try store.add(codex)
        XCTAssertTrue(
            coord.guardRefresh(profile: codex),
            "Claude's guardRefresh must not block a non-Claude profile when Claude CLI is not logged in"
        )
        // Counter-test: archived non-Claude profile is still denied.
        codex.kind = .archived
        XCTAssertFalse(coord.guardRefresh(profile: codex))
    }

    func test_claudeLogin_doesNotArchiveCodexAutoProfile() throws {
        let store = makeStore()
        let codex = Profile(
            name: "Codex",
            authMethod: .cliSync,
            providerID: .codex,
            email: "codex@x.com",
            kind: .auto,
            ownershipBoundary: t0
        )
        try store.add(codex)
        try store.setActive(id: codex.id)

        let watcher = FakeWatcher()
        let coord = makeCoordinator(
            watcher: watcher,
            profileStore: store,
            profileFetcher: AlwaysNilOAuthProfileFetcher(),
            alwaysAllowRefresh: true
        )
        coord.start()

        // Emit a Claude login.
        let identity = CLIIdentity(
            email: "claude@x.com",
            orgId: nil,
            credentialFingerprint: "fp"
        )
        watcher.emit(identity)

        let storedCodex = store.profiles.first { $0.id == codex.id }
        XCTAssertEqual(
            storedCodex?.kind, .auto,
            "Claude login must not archive a Codex profile via demoteOtherAutoProfiles"
        )
    }

    func test_probe_isNotCalled_whenIdentityIsNil() async throws {
        // Sign-out path: no identity to probe for.
        let store = makeStore()
        let stub = StubOAuthProfileFetcher()
        let watcher = FakeWatcher()
        let coord = makeCoordinator(
            watcher: watcher, profileStore: store,
            profileFetcher: stub,
            clock: { self.t0 }
        )
        coord.start()
        watcher.emit(nil)
        // Give any spurious task a chance to run.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(stub.callCount, 0)
    }

    // MARK: - active focus on appearance

    func test_appearance_whenOtherProviderActive_doesNotSteal() throws {
        let store = makeStore()
        try store.add(Profile(name: "Codex", authMethod: .cliSync,
                              providerID: .codex, organizationId: "acct",
                              email: "c@x.com", kind: .auto))
        let codexId = store.profiles[0].id
        try store.setActive(id: codexId)

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-a",
                                  credentialFingerprint: "ff"))

        XCTAssertTrue(store.profiles.contains { $0.providerID == .claude && $0.email == "a@x.com" },
                      "Claude profile is still created")
        XCTAssertEqual(store.activeProfileId, codexId,
                       "Claude appearing must not steal focus from the active Codex profile")
    }

    func test_firstEmit_crossProviderPersistedSelection_doesNotStealFocus() throws {
        let store = makeStore()
        try store.add(Profile(name: "Codex", authMethod: .cliSync,
                              providerID: .codex, organizationId: "acct",
                              email: "c@x.com", kind: .auto))
        let codexId = store.profiles[0].id
        try store.setActive(id: codexId)

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-a",
                                  credentialFingerprint: "ff"))

        XCTAssertTrue(store.profiles.contains { $0.providerID == .claude && $0.email == "a@x.com" },
                      "Claude profile must still be created on first emit")
        XCTAssertEqual(store.activeProfileId, codexId,
                       "first emit must not steal active from a cross-provider persisted pick")
    }

    func test_firstEmit_sameProviderMatchingSelection_keepsActive() throws {
        let store = makeStore()
        try store.add(Profile(name: "A", authMethod: .cliSync,
                              organizationId: "org-a", email: "a@x.com",
                              kind: .auto))
        let aId = store.profiles[0].id
        try store.setActive(id: aId)

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-a",
                                  credentialFingerprint: "ff"))

        XCTAssertEqual(store.activeProfileId, aId,
                       "matching same-provider selection stays active")
    }

    func test_firstEmit_sameProviderStaleSelection_followsCLI() throws {
        let store = makeStore()
        try store.add(Profile(name: "A", authMethod: .cliSync,
                              organizationId: "org-a", email: "a@x.com",
                              kind: .auto))
        let aId = store.profiles[0].id
        try store.setActive(id: aId)

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "b@x.com", orgId: "org-b",
                                  credentialFingerprint: "gg"))

        let bId = try XCTUnwrap(store.profiles.first { $0.email == "b@x.com" }?.id)
        XCTAssertEqual(store.activeProfileId, bId,
                       "stale persisted pick (CLI switched accounts) must follow the live account")
    }

    func test_firstEmit_persistedRemovedWhileClosed_autoDetects() throws {
        let store = makeStore()
        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-a",
                                  credentialFingerprint: "ff"))

        XCTAssertEqual(store.activeProfileId, store.profiles.first?.id,
                       "with no other profile active, appearance takes focus")
    }

    func test_secondEmit_genuineSwitch_stillFollows() throws {
        let store = makeStore()
        try store.add(Profile(name: "A", authMethod: .cliSync,
                              organizationId: "org-a", email: "a@x.com",
                              kind: .auto))
        let aId = store.profiles[0].id
        try store.setActive(id: aId)

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(CLIIdentity(email: "a@x.com", orgId: "org-a",
                                  credentialFingerprint: "ff"))
        XCTAssertEqual(store.activeProfileId, aId)
        watcher.emit(CLIIdentity(email: "b@x.com", orgId: "org-b",
                                  credentialFingerprint: "gg"))
        let bId = try XCTUnwrap(store.profiles.first { $0.email == "b@x.com" }?.id)
        XCTAssertEqual(store.activeProfileId, bId,
                       "mid-session following is preserved after the first emit")
    }

    func test_signOut_withLiveOtherProvider_handsOffActiveToThatProvider() throws {
        let store = makeStore()
        // Persisted pick: a Claude profile, active.
        try store.add(Profile(name: "A", authMethod: .cliSync,
                              providerID: .claude, organizationId: "org-a",
                              email: "a@x.com", kind: .auto))
        let claudeId = store.profiles[0].id
        // A live Codex profile also exists.
        try store.add(Profile(name: "Codex", authMethod: .cliSync,
                              providerID: .codex, organizationId: "acct",
                              email: "c@x.com", kind: .auto))
        let codexId = store.profiles[1].id
        try store.setActive(id: claudeId)

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        // Claude signed out at relaunch.
        watcher.emit(nil)

        // The Claude profile is archived and focus hands off to the live Codex.
        XCTAssertEqual(store.profiles.first { $0.id == claudeId }?.kind, .archived,
                       "active Claude profile is archived on sign-out")
        XCTAssertEqual(store.activeProfileId, codexId,
                       "focus hands off to the live other-provider profile, not the dead Claude one")
    }

    func test_signOut_claudeActive_noOtherProvider_clearsActive() throws {
        let store = makeStore()
        try store.add(Profile(name: "A", authMethod: .cliSync,
                              providerID: .claude, organizationId: "org-a",
                              email: "a@x.com", kind: .auto))
        let claudeId = store.profiles[0].id
        try store.setActive(id: claudeId)

        let watcher = FakeWatcher()
        let coord = makeCoordinator(watcher: watcher,
                                            profileStore: store,
                                            profileFetcher: AlwaysNilOAuthProfileFetcher(),
                                            clock: { self.t0 })
        coord.start()
        watcher.emit(nil)

        XCTAssertNil(store.activeProfileId,
                     "with no other live provider, sign-out clears active")
    }
}

@MainActor
final class FakeWatcher: CLIAccountWatching {
    var onChange: ((CLIIdentity?) -> Void)?
    private(set) var current: CLIIdentity?
    func start() {}
    func stop() {}
    func emit(_ identity: CLIIdentity?) {
        current = identity
        onChange?(identity)
    }
}

@MainActor
private final class StubOAuthProfileFetcher: OAuthProfileFetching {
    enum Outcome {
        case success(OAuthProfileFetcher.Response)
        case failure(Error)
    }
    var outcome: Outcome = .success(.init(
        planLabel: nil, orgUuid: nil, subscriptionCreatedAt: nil,
        subscriptionActive: false, hasExtraUsage: false,
        displayName: nil, email: nil,
        accountUuid: nil, accountCreatedAt: nil,
        organizationName: nil, subscriptionStatus: nil, billingType: nil
    ))
    private(set) var callCount = 0
    private(set) var capturedCredentials: [Credential] = []

    func fetch(credential: Credential) async throws -> OAuthProfileFetcher.Response {
        callCount += 1
        capturedCredentials.append(credential)
        switch outcome {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}

@MainActor
private final class AlwaysNilOAuthProfileFetcher: OAuthProfileFetching {
    func fetch(credential: Credential) async throws -> OAuthProfileFetcher.Response {
        OAuthProfileFetcher.Response(
            planLabel: nil, orgUuid: nil, subscriptionCreatedAt: nil,
            subscriptionActive: false, hasExtraUsage: false,
            displayName: nil, email: nil,
            accountUuid: nil, accountCreatedAt: nil,
            organizationName: nil, subscriptionStatus: nil, billingType: nil
        )
    }
}

private struct StubCredentialReader: CLICredentialReading {
    let stub: Credential
    func read() throws -> CLICredentialReader.SyncResult {
        CLICredentialReader.SyncResult(credential: stub, subscriptionPlan: nil)
    }
}
