//
//  CodexAutoProfileCoordinatorTests.swift
//

import XCTest
@testable import Kwota

@MainActor
final class CodexAutoProfileCoordinatorTests: XCTestCase {
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

    private func makeCoord(
        watcher: StubCodexAccountWatcher,
        authReader: any CodexAuthReaderProviding = StubCodexAuthReaderForCoord(token: "test-token")
    ) -> CodexAutoProfileCoordinator {
        CodexAutoProfileCoordinator(
            watcher: watcher,
            profileStore: profileStore,
            keychain: keychain,
            authReader: authReader,
            clock: { Date() }
        )
    }

    func test_newLogin_createsActiveCodexProfile() throws {
        let watcher = StubCodexAccountWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        watcher.emit(CodexIdentity(email: "u@x.com", accountId: "acct-1", credentialFingerprint: "fp"))

        let added = profileStore.profiles.first { $0.providerID == .codex }
        XCTAssertNotNil(added, "Login must create a Codex profile")
        XCTAssertEqual(added?.email, "u@x.com")
        XCTAssertEqual(added?.kind, .auto)
        XCTAssertEqual(profileStore.activeProfileId, added?.id)

        // Keychain must be seeded on new login.
        let stored = try keychain.read(for: added!.id)
        XCTAssertNotNil(stored, "Codex login must seed a Keychain credential")
        if case .cliToken(let access, _, _) = stored {
            XCTAssertFalse(access.isEmpty, "seeded access token must not be empty")
        } else {
            XCTFail("expected cliToken credential in keychain")
        }
    }

    func test_signOut_demotesCodexAndPreservesClaude() throws {
        // Pre-seed a Claude .auto profile so the smart-clearActive branch
        // sees an other-provider live profile.
        let claude = Profile(
            name: "Claude",
            authMethod: .cliSync,
            providerID: .claude,
            email: "c@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
        try profileStore.add(claude)

        let watcher = StubCodexAccountWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        // Codex login
        watcher.emit(CodexIdentity(email: "u@x.com", accountId: "acct-1", credentialFingerprint: "fp1"))
        let codexId = try XCTUnwrap(profileStore.profiles.first { $0.providerID == .codex }?.id)
        try profileStore.setActive(id: codexId)
        XCTAssertEqual(profileStore.activeProfileId, codexId)

        // Codex sign-out
        watcher.emit(nil)

        let codex = profileStore.profiles.first { $0.id == codexId }
        XCTAssertEqual(codex?.kind, .archived, "Codex profile demoted on Codex sign-out")
        XCTAssertEqual(profileStore.activeProfileId, claude.id,
                       "Claude profile takes focus when Codex signs out and a Claude auto profile is around")
    }

    func test_signOut_clearActive_whenNoOtherProviderLive() throws {
        let watcher = StubCodexAccountWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        watcher.emit(CodexIdentity(email: "u@x.com", accountId: "acct-1", credentialFingerprint: "fp"))
        XCTAssertNotNil(profileStore.activeProfileId)

        watcher.emit(nil)

        XCTAssertNil(profileStore.activeProfileId,
                     "No other live profile → clearActive() runs")
    }

    func test_loginAgain_matchesExistingProfileByEmail() throws {
        let watcher = StubCodexAccountWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        watcher.emit(CodexIdentity(email: "u@x.com", accountId: nil, credentialFingerprint: "fp1"))
        let firstId = try XCTUnwrap(profileStore.profiles.first { $0.providerID == .codex }?.id)

        // Sign out, sign back in.
        watcher.emit(nil)
        watcher.emit(CodexIdentity(email: "u@x.com", accountId: nil, credentialFingerprint: "fp2"))

        let codexProfiles = profileStore.profiles.filter { $0.providerID == .codex }
        XCTAssertEqual(codexProfiles.count, 1, "Second login must reuse the existing profile, not create a duplicate")
        XCTAssertEqual(codexProfiles.first?.id, firstId)
        XCTAssertEqual(codexProfiles.first?.kind, .auto, "Archived profile is promoted back on re-login")
        XCTAssertEqual(profileStore.activeProfileId, firstId)
    }

    // MARK: - Authenticated-but-unidentified (nil email) safety
    //
    // Regression for Codex adversarial review (2026-05-25): the previous
    // `guard let identity, let email = identity.email else { sign-out }`
    // conflated "no identity" with "identity present but no email". A real
    // ~/.codex/auth.json with a valid access_token but unparseable id_token
    // would emit `CodexIdentity(email: nil, ...)`, falling into the
    // sign-out branch and archiving an already-authenticated Codex profile.

    func test_emitWithNilEmail_doesNotArchiveActiveCodexProfile() throws {
        let watcher = StubCodexAccountWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        // First, real login establishes an active Codex profile.
        watcher.emit(CodexIdentity(email: "u@x.com", accountId: "acct-1", credentialFingerprint: "fp1"))
        let codexId = try XCTUnwrap(profileStore.profiles.first { $0.providerID == .codex }?.id)

        // Now simulate auth.json rotating to a state where access_token is
        // still present but id_token's email claim can't be parsed.
        watcher.emit(CodexIdentity(email: nil, accountId: "acct-1", credentialFingerprint: "fp2"))

        let codex = profileStore.profiles.first { $0.id == codexId }
        XCTAssertEqual(
            codex?.kind, .auto,
            "Authenticated-but-unidentified emit must not archive an active Codex profile"
        )
        XCTAssertEqual(
            profileStore.activeProfileId, codexId,
            "Authenticated-but-unidentified emit must not clear the active Codex profile"
        )
    }

    func test_emitWithNilEmail_doesNotCreatePhantomProfile() throws {
        let watcher = StubCodexAccountWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        // No prior profile. Emit identity with no email (token present, JWT unparseable).
        watcher.emit(CodexIdentity(email: nil, accountId: nil, credentialFingerprint: "fp"))

        let codexProfiles = profileStore.profiles.filter { $0.providerID == .codex }
        XCTAssertEqual(
            codexProfiles.count, 0,
            "Authenticated-but-unidentified emit must not create a phantom profile we can't match later"
        )
        XCTAssertNil(profileStore.activeProfileId)
    }

    func test_emitWithNilEmail_doesNotTouchClaudeProfile() throws {
        // Adversarial concern: a Codex nil-email emit must not even
        // accidentally interfere with a Claude profile via the sign-out
        // branch's cross-provider logic.
        let claude = Profile(
            name: "Claude",
            authMethod: .cliSync,
            providerID: .claude,
            email: "c@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
        try profileStore.add(claude)
        try profileStore.setActive(id: claude.id)

        let watcher = StubCodexAccountWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        watcher.emit(CodexIdentity(email: nil, accountId: nil, credentialFingerprint: "fp"))

        let storedClaude = profileStore.profiles.first { $0.id == claude.id }
        XCTAssertEqual(storedClaude?.kind, .auto, "Claude profile must be untouched")
        XCTAssertEqual(profileStore.activeProfileId, claude.id, "Claude profile stays active")
    }

    // MARK: - Display name + renewal date plumbing

    func test_newLogin_usesJwtName_whenPresent() throws {
        let watcher = StubCodexAccountWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        let renewsAt = Date(timeIntervalSince1970: 1_780_000_000)
        watcher.emit(CodexIdentity(
            email: "u@x.com",
            accountId: "acct-1",
            credentialFingerprint: "fp",
            name: "Hau",
            subscriptionActiveUntil: renewsAt
        ))

        let added = try XCTUnwrap(profileStore.profiles.first { $0.providerID == .codex })
        XCTAssertEqual(added.name, "Hau",
                       "JWT name claim must populate Profile.name when present")
        XCTAssertEqual(added.subscriptionRenewsAt?.timeIntervalSince1970.rounded(),
                       renewsAt.timeIntervalSince1970.rounded(),
                       "JWT subscription_active_until must populate Profile.subscriptionRenewsAt")
    }

    func test_newLogin_fallsBackToEmail_whenNameClaimAbsent() throws {
        let watcher = StubCodexAccountWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        watcher.emit(CodexIdentity(
            email: "u@x.com",
            accountId: "acct-1",
            credentialFingerprint: "fp",
            name: nil,
            subscriptionActiveUntil: nil
        ))

        let added = try XCTUnwrap(profileStore.profiles.first { $0.providerID == .codex })
        XCTAssertEqual(added.name, "u@x.com",
                       "Profile.name must fall back to email when JWT name claim is absent")
        XCTAssertNil(added.subscriptionRenewsAt)
    }

    func test_existingProfile_syncsNameAndRenewsAt_whenTheyDiffer() throws {
        // Seed a profile that predates this feature: name == email, no
        // renewal date. Next watcher emit carries a name + renewal — both
        // must be synced onto the persisted profile.
        let existing = Profile(
            name: "u@x.com",
            authMethod: .cliSync,
            providerID: .codex,
            organizationId: "acct-1",
            email: "u@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
        try profileStore.add(existing)

        let watcher = StubCodexAccountWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        let renewsAt = Date(timeIntervalSince1970: 1_780_000_000)
        watcher.emit(CodexIdentity(
            email: "u@x.com",
            accountId: "acct-1",
            credentialFingerprint: "fp",
            name: "Hau",
            subscriptionActiveUntil: renewsAt
        ))

        let updated = try XCTUnwrap(profileStore.profiles.first { $0.id == existing.id })
        XCTAssertEqual(updated.name, "Hau",
                       "Existing profile name must sync to JWT name on watcher emit")
        XCTAssertEqual(updated.subscriptionRenewsAt?.timeIntervalSince1970.rounded(),
                       renewsAt.timeIntervalSince1970.rounded(),
                       "Existing profile subscriptionRenewsAt must sync to JWT value")
    }

    func test_existingProfile_noWriteWhenValuesMatch() throws {
        // Sync writes must be diffed — otherwise every poll tick would
        // thrash the profile store with identical updates.
        let renewsAt = Date(timeIntervalSince1970: 1_780_000_000)
        let existing = Profile(
            name: "Hau",
            authMethod: .cliSync,
            providerID: .codex,
            organizationId: "acct-1",
            subscriptionRenewsAt: renewsAt,
            email: "u@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
        try profileStore.add(existing)
        let lastFetchedBefore = existing.lastFetchedAt

        let watcher = StubCodexAccountWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        // Emit identical info. Coordinator must not rewrite the profile.
        watcher.emit(CodexIdentity(
            email: "u@x.com",
            accountId: "acct-1",
            credentialFingerprint: "fp",
            name: "Hau",
            subscriptionActiveUntil: renewsAt
        ))

        let after = try XCTUnwrap(profileStore.profiles.first { $0.id == existing.id })
        XCTAssertEqual(after.name, "Hau")
        XCTAssertEqual(after.subscriptionRenewsAt?.timeIntervalSince1970.rounded(),
                       renewsAt.timeIntervalSince1970.rounded())
        XCTAssertEqual(after.lastFetchedAt, lastFetchedBefore,
                       "No-op sync must not bump lastFetchedAt")
    }

    // MARK: - launch snapshot (restore last-active on relaunch)

    func test_firstEmit_crossProviderActive_doesNotStealFocus() throws {
        try profileStore.add(Profile(name: "Claude", authMethod: .cliSync,
                                     providerID: .claude, organizationId: "org",
                                     email: "cl@x.com", kind: .auto))
        let claudeId = profileStore.profiles[0].id
        try profileStore.setActive(id: claudeId)

        let watcher = StubCodexAccountWatcher()
        let coord = CodexAutoProfileCoordinator(
            watcher: watcher,
            profileStore: profileStore,
            keychain: keychain,
            authReader: StubCodexAuthReaderForCoord(token: "test-token"),
            clock: { Date() }
        )
        coord.start()
        watcher.emit(CodexIdentity(email: "u@x.com", accountId: "acct-1", credentialFingerprint: "fp"))

        XCTAssertTrue(profileStore.profiles.contains { $0.providerID == .codex && $0.email == "u@x.com" },
                      "Codex profile must still be created on first emit")
        XCTAssertEqual(profileStore.activeProfileId, claudeId,
                       "first emit must not steal active from a cross-provider persisted pick")
    }

    func test_firstEmit_sameProviderMatchingSelection_keepsActive() throws {
        try profileStore.add(Profile(name: "U", authMethod: .cliSync,
                                     providerID: .codex, organizationId: "acct-1",
                                     email: "u@x.com", kind: .auto))
        let uId = profileStore.profiles[0].id
        try profileStore.setActive(id: uId)

        let watcher = StubCodexAccountWatcher()
        let coord = CodexAutoProfileCoordinator(
            watcher: watcher,
            profileStore: profileStore,
            keychain: keychain,
            authReader: StubCodexAuthReaderForCoord(token: "test-token"),
            clock: { Date() }
        )
        coord.start()
        watcher.emit(CodexIdentity(email: "u@x.com", accountId: "acct-1", credentialFingerprint: "fp"))

        XCTAssertEqual(profileStore.activeProfileId, uId,
                       "matching same-provider selection stays active")
    }

    func test_firstEmit_sameProviderStaleSelection_followsCLI() throws {
        try profileStore.add(Profile(name: "U", authMethod: .cliSync,
                                     providerID: .codex, organizationId: "acct-1",
                                     email: "u@x.com", kind: .auto))
        let uId = profileStore.profiles[0].id
        try profileStore.setActive(id: uId)

        let watcher = StubCodexAccountWatcher()
        let coord = CodexAutoProfileCoordinator(
            watcher: watcher,
            profileStore: profileStore,
            keychain: keychain,
            authReader: StubCodexAuthReaderForCoord(token: "test-token"),
            clock: { Date() }
        )
        coord.start()
        watcher.emit(CodexIdentity(email: "v@x.com", accountId: "acct-2", credentialFingerprint: "fp2"))

        let vId = try XCTUnwrap(profileStore.profiles.first { $0.email == "v@x.com" }?.id)
        XCTAssertEqual(profileStore.activeProfileId, vId,
                       "stale persisted pick must follow the live Codex account")
    }

    func test_secondEmit_genuineSwitch_stillFollows() throws {
        try profileStore.add(Profile(name: "U", authMethod: .cliSync,
                                     providerID: .codex, organizationId: "acct-1",
                                     email: "u@x.com", kind: .auto))
        let uId = profileStore.profiles[0].id
        try profileStore.setActive(id: uId)

        let watcher = StubCodexAccountWatcher()
        let coord = CodexAutoProfileCoordinator(
            watcher: watcher,
            profileStore: profileStore,
            keychain: keychain,
            authReader: StubCodexAuthReaderForCoord(token: "test-token"),
            clock: { Date() }
        )
        coord.start()
        watcher.emit(CodexIdentity(email: "u@x.com", accountId: "acct-1", credentialFingerprint: "fp"))
        XCTAssertEqual(profileStore.activeProfileId, uId)
        watcher.emit(CodexIdentity(email: "v@x.com", accountId: "acct-2", credentialFingerprint: "fp2"))
        let vId = try XCTUnwrap(profileStore.profiles.first { $0.email == "v@x.com" }?.id)
        XCTAssertEqual(profileStore.activeProfileId, vId,
                       "mid-session following is preserved after the first emit")
    }

    func test_appearance_whenOtherProviderActive_doesNotSteal() throws {
        // Claude active; Codex logs in afterward → must not steal.
        let claude = Profile(name: "Claude", authMethod: .cliSync,
                             providerID: .claude, email: "c@x.com", kind: .auto)
        try profileStore.add(claude)
        try profileStore.setActive(id: claude.id)

        let watcher = StubCodexAccountWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()
        watcher.emit(CodexIdentity(email: "k@x.com", accountId: "acct-k", credentialFingerprint: "fp"))

        XCTAssertTrue(profileStore.profiles.contains { $0.providerID == .codex },
                      "Codex profile is still created")
        XCTAssertEqual(profileStore.activeProfileId, claude.id,
                       "Codex appearing must not steal focus from the active Claude profile")
    }
}

private struct StubCodexAuthReaderForCoord: CodexAuthReaderProviding {
    let token: String?
    func read() -> CodexAuthReader.Auth? {
        guard let token, !token.isEmpty else { return nil }
        return CodexAuthReader.Auth(
            accessToken: token,
            refreshToken: "r",
            idToken: nil,
            accountId: nil,
            email: "u@x.com",
            name: nil,
            subscriptionActiveUntil: nil
        )
    }
}

@MainActor
final class StubCodexAccountWatcher: CodexAccountWatching {
    var onChange: ((CodexIdentity?) -> Void)?
    private(set) var current: CodexIdentity?
    func start() {}
    func stop() {}
    func emit(_ identity: CodexIdentity?) {
        current = identity
        onChange?(identity)
    }
}
