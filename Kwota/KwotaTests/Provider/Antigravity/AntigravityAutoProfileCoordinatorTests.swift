//
//  AntigravityAutoProfileCoordinatorTests.swift
//

import XCTest
@testable import Kwota

@MainActor
final class AntigravityAutoProfileCoordinatorTests: XCTestCase {
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

    private func makeCoord(watcher: StubAntigravityProcessWatcher) -> AntigravityAutoProfileCoordinator {
        AntigravityAutoProfileCoordinator(
            watcher: watcher,
            profileStore: profileStore,
            clock: { Date() }
        )
    }

    private func makeIdentity(token: String = "csrf-1", port: Int = 9000) -> AntigravityIdentity {
        AntigravityIdentity(
            csrfToken: token,
            port: port,
            credentialFingerprint: String(token.suffix(8))
        )
    }

    func test_identityAppears_createsAutoProfile() throws {
        let watcher = StubAntigravityProcessWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        watcher.emit(makeIdentity())

        let added = profileStore.profiles.first { $0.providerID == .antigravity }
        XCTAssertNotNil(added, "Identity emit must create an Antigravity profile")
        XCTAssertEqual(added?.kind, .auto)
        XCTAssertEqual(added?.name, "Antigravity")
        XCTAssertNil(added?.email)
        XCTAssertEqual(profileStore.activeProfileId, added?.id)
    }

    func test_identityDisappears_archivesActiveProfile() throws {
        let watcher = StubAntigravityProcessWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        watcher.emit(makeIdentity())
        let id = try XCTUnwrap(profileStore.profiles.first { $0.providerID == .antigravity }?.id)

        watcher.emit(nil)

        let after = profileStore.profiles.first { $0.id == id }
        XCTAssertEqual(after?.kind, .archived, "Profile must be archived when identity disappears")
        XCTAssertNil(profileStore.activeProfileId,
                     "No other-provider live profile → activeProfileId is nil")
    }

    func test_identityReappears_promotesArchivedProfile() throws {
        let watcher = StubAntigravityProcessWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        watcher.emit(makeIdentity(token: "csrf-1"))
        let firstId = try XCTUnwrap(profileStore.profiles.first { $0.providerID == .antigravity }?.id)

        watcher.emit(nil)
        // CSRF rotates on Antigravity app restart — second emit carries a
        // different token but coordinator must still re-promote, not duplicate.
        watcher.emit(makeIdentity(token: "csrf-2-rotated"))

        let agProfiles = profileStore.profiles.filter { $0.providerID == .antigravity }
        XCTAssertEqual(agProfiles.count, 1, "Re-emit after rotation must reuse the existing profile")
        XCTAssertEqual(agProfiles.first?.id, firstId)
        XCTAssertEqual(agProfiles.first?.kind, .auto, "Archived profile must be promoted back to .auto")
        XCTAssertEqual(profileStore.activeProfileId, firstId)
    }

    func test_identityAppears_whenOtherProviderActive_doesNotTakeActive() throws {
        // Pre-seed a Claude auto profile, active.
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

        let watcher = StubAntigravityProcessWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        watcher.emit(makeIdentity())

        let ag = try XCTUnwrap(profileStore.profiles.first { $0.providerID == .antigravity })
        XCTAssertEqual(ag.kind, .auto, "Antigravity profile is still created and visible")
        XCTAssertEqual(profileStore.activeProfileId, claude.id,
                       "Antigravity appearing must not steal focus from the active Claude profile")
        let claudeAfter = profileStore.profiles.first { $0.id == claude.id }
        XCTAssertEqual(claudeAfter?.kind, .auto, "Claude remains .auto")
    }

    func test_identityReappears_whenOtherProviderActive_doesNotSteal() throws {
        let claude = Profile(
            name: "Claude", authMethod: .cliSync, providerID: .claude,
            email: "c@x.com", kind: .auto, ownershipBoundary: Date())
        try profileStore.add(claude)

        let watcher = StubAntigravityProcessWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        // Antigravity present, then the user switches focus to Claude.
        watcher.emit(makeIdentity(token: "csrf-1"))
        try profileStore.setActive(id: claude.id)

        // Turn Antigravity off, then on (CSRF rotates on restart).
        watcher.emit(nil)
        watcher.emit(makeIdentity(token: "csrf-2-rotated"))

        let ag = try XCTUnwrap(profileStore.profiles.first { $0.providerID == .antigravity })
        XCTAssertEqual(ag.kind, .auto, "Antigravity is re-promoted / visible again")
        XCTAssertEqual(profileStore.activeProfileId, claude.id,
                       "re-appearance must not steal focus back from Claude")
    }

    func test_archiveActiveAntigravityProfile_directCall() throws {
        let watcher = StubAntigravityProcessWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        watcher.emit(makeIdentity())
        let id = try XCTUnwrap(profileStore.profiles.first { $0.providerID == .antigravity }?.id)

        coord.archiveActiveAntigravityProfile()

        let after = profileStore.profiles.first { $0.id == id }
        XCTAssertEqual(after?.kind, .archived)

        // Idempotency: second call is a no-op (profile already archived).
        coord.archiveActiveAntigravityProfile()
        let after2 = profileStore.profiles.first { $0.id == id }
        XCTAssertEqual(after2?.kind, .archived)
    }

    func test_identityDisappears_whenOtherProviderProfileExists_promotesIt() throws {
        let claude = Profile(
            name: "Claude",
            authMethod: .cliSync,
            providerID: .claude,
            email: "c@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
        try profileStore.add(claude)

        let watcher = StubAntigravityProcessWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        watcher.emit(makeIdentity())
        let agId = try XCTUnwrap(profileStore.profiles.first { $0.providerID == .antigravity }?.id)
        try profileStore.setActive(id: agId)
        XCTAssertEqual(profileStore.activeProfileId, agId)

        watcher.emit(nil)

        let agAfter = profileStore.profiles.first { $0.id == agId }
        XCTAssertEqual(agAfter?.kind, .archived)
        XCTAssertEqual(profileStore.activeProfileId, claude.id,
                       "Claude takes focus when Antigravity disappears")
    }

    func test_freshCreate_archivesStaleSiblingAntigravityAutoProfiles() throws {
        // Reproduce the bug: stale Antigravity .auto profile lingers when
        // active is something else (Codex), then Antigravity emits → must
        // archive the stale sibling so only one .auto Antigravity exists.
        let watcher = StubAntigravityProcessWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        // Pre-seed: stale Antigravity .auto + active Codex .auto.
        let stale = Profile(
            name: "Antigravity",
            authMethod: .cliSync,
            providerID: .antigravity,
            organizationId: nil,
            subscriptionRenewsAt: nil,
            email: nil,
            kind: .auto,
            ownershipBoundary: Date()
        )
        let codex = Profile(
            name: "Codex",
            authMethod: .cliSync,
            providerID: .codex,
            organizationId: nil,
            subscriptionRenewsAt: nil,
            email: nil,
            kind: .auto,
            ownershipBoundary: Date()
        )
        try profileStore.add(stale)
        try profileStore.add(codex)
        try profileStore.setActive(id: codex.id)

        // Trigger: Antigravity emits with a new CSRF (process restart).
        watcher.emit(makeIdentity(token: "new-csrf"))

        // Expect: exactly one Antigravity .auto profile (the new one), and
        // the stale one is now .archived.
        let antigravityAuto = profileStore.profiles.filter {
            $0.providerID == .antigravity && $0.kind == .auto
        }
        XCTAssertEqual(antigravityAuto.count, 1, "must have exactly one .auto Antigravity profile")
        let staleAfter = profileStore.profiles.first { $0.id == stale.id }
        XCTAssertEqual(staleAfter?.kind, .archived, "stale Antigravity profile must be archived")
    }

    func test_promoteArchived_archivesStaleSiblingAntigravityAutoProfiles() throws {
        // Similar to above, but with an archived match available — also test
        // that the promote path archives stale siblings.
        let watcher = StubAntigravityProcessWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        let archived = Profile(
            name: "Antigravity",
            authMethod: .cliSync,
            providerID: .antigravity,
            organizationId: nil,
            subscriptionRenewsAt: nil,
            email: "old@example.com",
            kind: .archived,
            ownershipBoundary: Date()
        )
        let stale = Profile(
            name: "Antigravity",
            authMethod: .cliSync,
            providerID: .antigravity,
            organizationId: nil,
            subscriptionRenewsAt: nil,
            email: nil,
            kind: .auto,
            ownershipBoundary: Date()
        )
        let codex = Profile(
            name: "Codex",
            authMethod: .cliSync,
            providerID: .codex,
            organizationId: nil,
            subscriptionRenewsAt: nil,
            email: nil,
            kind: .auto,
            ownershipBoundary: Date()
        )
        try profileStore.add(archived)
        try profileStore.add(stale)
        try profileStore.add(codex)
        try profileStore.setActive(id: codex.id)

        watcher.emit(makeIdentity(token: "rotated"))

        // The archived profile should be promoted; the stale .auto should be
        // archived. Exactly one .auto Antigravity profile must remain.
        let antigravityAuto = profileStore.profiles.filter {
            $0.providerID == .antigravity && $0.kind == .auto
        }
        XCTAssertEqual(antigravityAuto.count, 1)
        XCTAssertEqual(antigravityAuto.first?.id, archived.id, "must promote the archived, not create new")
        let staleAfter = profileStore.profiles.first { $0.id == stale.id }
        XCTAssertEqual(staleAfter?.kind, .archived)
    }

    func test_duplicateIdentityEmit_isNoOp() throws {
        let watcher = StubAntigravityProcessWatcher()
        let coord = makeCoord(watcher: watcher)
        coord.start()

        let id = makeIdentity()
        watcher.emit(id)
        watcher.emit(id)

        let agProfiles = profileStore.profiles.filter { $0.providerID == .antigravity }
        XCTAssertEqual(agProfiles.count, 1, "Duplicate identity emits must only create one profile")
    }

    // MARK: - launch snapshot (restore last-active on relaunch)

    func test_firstEmit_crossProviderActive_doesNotStealFocus() throws {
        try profileStore.add(Profile(name: "Claude", authMethod: .cliSync,
                                     providerID: .claude, organizationId: "org",
                                     email: "cl@x.com", kind: .auto))
        let claudeId = profileStore.profiles[0].id
        try profileStore.setActive(id: claudeId)

        let watcher = StubAntigravityProcessWatcher()
        let coord = AntigravityAutoProfileCoordinator(
            watcher: watcher,
            profileStore: profileStore,
            keychain: keychain,
            clock: { Date() }
        )
        coord.start()
        watcher.emit(makeIdentity())

        XCTAssertTrue(profileStore.profiles.contains { $0.providerID == .antigravity },
                      "Antigravity profile must still be created on first emit")
        XCTAssertEqual(profileStore.activeProfileId, claudeId,
                       "first emit must not steal active from a cross-provider persisted pick")
    }

    func test_firstEmit_noPersistedSelection_activatesNewProfile() throws {
        let watcher = StubAntigravityProcessWatcher()
        let coord = AntigravityAutoProfileCoordinator(
            watcher: watcher,
            profileStore: profileStore,
            keychain: keychain,
            clock: { Date() }
        )
        coord.start()
        watcher.emit(makeIdentity())

        let added = try XCTUnwrap(profileStore.profiles.first { $0.providerID == .antigravity })
        XCTAssertEqual(profileStore.activeProfileId, added.id,
                       "with no persisted pick the new Antigravity profile becomes active")
    }
}

@MainActor
final class StubAntigravityProcessWatcher: AntigravityProcessWatching {
    var onChange: ((AntigravityIdentity?) -> Void)?
    private(set) var current: AntigravityIdentity?
    var pokeNowCallCount = 0
    func start() {}
    func stop() {}
    func pokeNow() { pokeNowCallCount += 1 }
    func popoverDidOpen() {}
    func popoverDidClose() {}
    func emit(_ identity: AntigravityIdentity?) {
        current = identity
        onChange?(identity)
    }
}
