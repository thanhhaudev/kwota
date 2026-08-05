//
//  CodexTokenRefresherTests.swift
//

import XCTest
@testable import Kwota

@MainActor
final class CodexTokenRefresherTests: XCTestCase {
    private var keychain: KeychainCredentialStore!
    private var profileId: UUID!

    override func setUp() async throws {
        try await super.setUp()
        keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        profileId = UUID()
    }

    override func tearDown() async throws {
        try? await keychain.deleteAll()
        try await super.tearDown()
    }

    private func makeReader(accessToken: String?, email: String? = nil) -> CodexAuthReaderProviding {
        StubCodexAuthReader(token: accessToken, email: email)
    }

    func test_freshen_returnsCurrent_whenAccessTokenHasHeadroom() async throws {
        let now = Date()
        let current = Credential.cliToken(
            accessToken: "old",
            refreshToken: "r",
            expiresAt: now.addingTimeInterval(3600)  // 1h ahead, well above minLifetime
        )
        let refresher = CodexTokenRefresher(
            reader: makeReader(accessToken: "new-from-disk"),
            store: keychain,
            now: { now }
        )
        let result = try await refresher.freshen(profileId: profileId, current: current)
        if case .cliToken(let access, _, _) = result {
            XCTAssertEqual(access, "old",
                           "Cheap-path: still-valid token must be returned unchanged, no disk read")
        } else {
            XCTFail("Expected cliToken")
        }
    }

    func test_freshen_reReadsFromDisk_whenAccessTokenWithinMinLifetime() async throws {
        let now = Date()
        let current = Credential.cliToken(
            accessToken: "old",
            refreshToken: "r",
            expiresAt: now.addingTimeInterval(30)  // 30s — within 60s minLifetime
        )
        let refresher = CodexTokenRefresher(
            reader: makeReader(accessToken: "new-from-disk"),
            store: keychain,
            now: { now }
        )
        let result = try await refresher.freshen(profileId: profileId, current: current)
        if case .cliToken(let access, _, _) = result {
            XCTAssertEqual(access, "new-from-disk",
                           "Re-read path: when local expiry is near, return the rotated token from auth.json")
        } else {
            XCTFail("Expected cliToken")
        }
    }

    func test_forceRefresh_returnsNil_whenAuthJsonHasSameToken() async throws {
        let previous = Credential.cliToken(
            accessToken: "stuck",
            refreshToken: "r",
            expiresAt: .distantFuture
        )
        let refresher = CodexTokenRefresher(
            reader: makeReader(accessToken: "stuck"),
            store: keychain,
            now: { Date() }
        )
        let result = try await refresher.forceRefresh(profileId: profileId, previous: previous)
        XCTAssertNil(
            result,
            "When auth.json carries the same token as the failing previous, retrying would 401 again — return nil"
        )
    }

    func test_forceRefresh_returnsRotatedToken_whenAuthJsonChanged() async throws {
        let previous = Credential.cliToken(
            accessToken: "expired",
            refreshToken: "r",
            expiresAt: .distantFuture
        )
        let refresher = CodexTokenRefresher(
            reader: makeReader(accessToken: "rotated"),
            store: keychain,
            now: { Date() }
        )
        let refreshed = try await refresher.forceRefresh(profileId: profileId, previous: previous)
        let result = try XCTUnwrap(refreshed)
        if case .cliToken(let access, _, _) = result {
            XCTAssertEqual(access, "rotated")
        } else {
            XCTFail("Expected cliToken")
        }
    }

    // MARK: - expectedEmail identity gate (Finding 1)

    /// Mirrors `CLITokenRefresherTests`' identityCheck-returning-false
    /// coverage: if the on-disk account has changed between
    /// `CodexProvider.fetchUsage`'s pre-check and this method's own
    /// `auth.json` read, the read's account must never be written under the
    /// profile the caller asked to refresh.
    func test_freshen_doesNotWrite_whenOnDiskEmailDoesNotMatchExpected() async throws {
        let now = Date()
        let current = Credential.cliToken(
            accessToken: "old",
            refreshToken: "r",
            expiresAt: now.addingTimeInterval(30)  // within minLifetime — forces the re-read path
        )
        let refresher = CodexTokenRefresher(
            reader: makeReader(accessToken: "other-account-token", email: "attacker@example.com"),
            store: keychain,
            now: { now }
        )
        let result = try await refresher.freshen(
            profileId: profileId,
            current: current,
            expectedEmail: "owner@example.com"
        )
        XCTAssertEqual(result, current,
                       "must hand back this profile's own token, not the other account's")
        let persisted = try await keychain.read(for: profileId)
        XCTAssertNil(persisted,
                     "the other account's token must never be persisted under this profile")
    }

    /// The gate must not become "never rotate" — a matching email still
    /// lets a genuine rotation through.
    func test_freshen_stillWrites_whenOnDiskEmailMatchesExpected() async throws {
        let now = Date()
        let current = Credential.cliToken(
            accessToken: "old",
            refreshToken: "r",
            expiresAt: now.addingTimeInterval(30)
        )
        let refresher = CodexTokenRefresher(
            reader: makeReader(accessToken: "rotated-token", email: "Owner@Example.com"),
            store: keychain,
            now: { now }
        )
        let result = try await refresher.freshen(
            profileId: profileId,
            current: current,
            expectedEmail: "owner@example.com"
        )
        if case .cliToken(let access, _, _) = result {
            XCTAssertEqual(access, "rotated-token", "case-insensitive match must still rotate")
        } else {
            XCTFail("Expected cliToken")
        }
        let persisted = try await keychain.read(for: profileId)
        XCTAssertEqual(persisted, result)
    }

    /// Same race on the 401 recovery path — a mismatched token here would be
    /// both persisted AND handed straight back for an immediate API retry.
    func test_forceRefresh_returnsNil_whenOnDiskEmailDoesNotMatchExpected() async throws {
        let previous = Credential.cliToken(
            accessToken: "mine",
            refreshToken: "r",
            expiresAt: .distantFuture
        )
        let refresher = CodexTokenRefresher(
            reader: makeReader(accessToken: "other-account-token", email: "attacker@example.com"),
            store: keychain,
            now: { Date() }
        )
        let result = try await refresher.forceRefresh(
            profileId: profileId,
            previous: previous,
            expectedEmail: "owner@example.com"
        )
        XCTAssertNil(result, "a token from another account must not be retried with")
        let persisted = try await keychain.read(for: profileId)
        XCTAssertNil(persisted, "nor persisted under this profile on the way past")
    }

    /// `expectedEmail: nil` (nothing to compare against) must proceed
    /// exactly as before this fix — an already-working profile that never
    /// supplies an expectation must not start failing.
    func test_freshen_proceeds_whenExpectedEmailIsNil() async throws {
        let now = Date()
        let current = Credential.cliToken(
            accessToken: "old",
            refreshToken: "r",
            expiresAt: now.addingTimeInterval(30)
        )
        let refresher = CodexTokenRefresher(
            reader: makeReader(accessToken: "rotated-token", email: "someone@example.com"),
            store: keychain,
            now: { now }
        )
        let result = try await refresher.freshen(
            profileId: profileId,
            current: current,
            expectedEmail: nil
        )
        if case .cliToken(let access, _, _) = result {
            XCTAssertEqual(access, "rotated-token")
        } else {
            XCTFail("Expected cliToken")
        }
    }
}

private struct StubCodexAuthReader: CodexAuthReaderProviding {
    let token: String?
    let email: String?
    func read() -> CodexAuthReader.Auth? {
        guard let token, !token.isEmpty else { return nil }
        return CodexAuthReader.Auth(
            accessToken: token,
            refreshToken: "r",
            idToken: nil,
            accountId: nil,
            email: email,
            name: nil,
            subscriptionActiveUntil: nil,
            planType: nil
        )
    }
}
