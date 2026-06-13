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
        try? keychain.deleteAll()
        try await super.tearDown()
    }

    private func makeReader(accessToken: String?) -> CodexAuthReaderProviding {
        StubCodexAuthReader(token: accessToken)
    }

    func test_freshen_returnsCurrent_whenAccessTokenHasHeadroom() throws {
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
        let result = try refresher.freshen(profileId: profileId, current: current)
        if case .cliToken(let access, _, _) = result {
            XCTAssertEqual(access, "old",
                           "Cheap-path: still-valid token must be returned unchanged, no disk read")
        } else {
            XCTFail("Expected cliToken")
        }
    }

    func test_freshen_reReadsFromDisk_whenAccessTokenWithinMinLifetime() throws {
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
        let result = try refresher.freshen(profileId: profileId, current: current)
        if case .cliToken(let access, _, _) = result {
            XCTAssertEqual(access, "new-from-disk",
                           "Re-read path: when local expiry is near, return the rotated token from auth.json")
        } else {
            XCTFail("Expected cliToken")
        }
    }

    func test_forceRefresh_returnsNil_whenAuthJsonHasSameToken() throws {
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
        XCTAssertNil(
            try refresher.forceRefresh(profileId: profileId, previous: previous),
            "When auth.json carries the same token as the failing previous, retrying would 401 again — return nil"
        )
    }

    func test_forceRefresh_returnsRotatedToken_whenAuthJsonChanged() throws {
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
        let result = try XCTUnwrap(
            try refresher.forceRefresh(profileId: profileId, previous: previous)
        )
        if case .cliToken(let access, _, _) = result {
            XCTAssertEqual(access, "rotated")
        } else {
            XCTFail("Expected cliToken")
        }
    }
}

private struct StubCodexAuthReader: CodexAuthReaderProviding {
    let token: String?
    func read() -> CodexAuthReader.Auth? {
        guard let token, !token.isEmpty else { return nil }
        return CodexAuthReader.Auth(
            accessToken: token,
            refreshToken: "r",
            idToken: nil,
            accountId: nil,
            email: nil,
            name: nil,
            subscriptionActiveUntil: nil,
            planType: nil
        )
    }
}
