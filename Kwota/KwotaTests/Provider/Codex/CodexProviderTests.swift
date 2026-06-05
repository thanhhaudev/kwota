//
//  CodexProviderTests.swift
//

import XCTest
@testable import Kwota

@MainActor
final class CodexProviderTests: XCTestCase {
    private var keychain: KeychainCredentialStore!
    private var profileStore: ProfileStore!

    override func setUp() async throws {
        try await super.setUp()
        keychain = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwota-tests-\(UUID().uuidString)", isDirectory: true)
        profileStore = ProfileStore(
            profilesFile: temp.appendingPathComponent("profiles.json"),
            keychain: keychain,
            profileDirectoryProvider: { temp.appendingPathComponent($0.uuidString) }
        )
    }

    override func tearDown() async throws {
        try? keychain.deleteAll()
        try await super.tearDown()
    }

    private func makeProvider(
        apiClient: CodexAPIClient,
        readerStub: any CodexAuthReaderProviding
    ) -> CodexProvider {
        let refresher = CodexTokenRefresher(reader: readerStub, store: keychain, now: { Date() })
        return CodexProvider(
            apiClient: apiClient,
            authReader: readerStub,
            tokenRefresher: refresher,
            profileStore: profileStore
        )
    }

    private func makeProfile() -> Profile {
        Profile(
            name: "Codex",
            authMethod: .cliSync,
            providerID: .codex,
            email: "u@x.com",
            kind: .auto,
            ownershipBoundary: Date()
        )
    }

    private func makeCredential() -> Credential {
        .cliToken(accessToken: "acc", refreshToken: "r", expiresAt: .distantFuture)
    }

    func test_reauthCopy_namesTheCodexCLI() {
        let provider = makeProvider(
            apiClient: CodexAPIClient(transport: { _ in throw URLError(.unknown) }),
            readerStub: StubCodexAuthReader(token: "acc")
        )
        XCTAssertEqual(provider.reauthTitle, "Codex CLI session expired")
        XCTAssertTrue(provider.reauthInstruction.contains("codex login"),
                      "Codex re-auth detail must reference `codex login`")
    }

    func testSupportedProfileDetailFieldsIsEmailAndOrgUUID() {
        let provider = makeProvider(
            apiClient: CodexAPIClient(transport: { _ in throw URLError(.unknown) }),
            readerStub: StubCodexAuthReader(token: "acc")
        )
        XCTAssertEqual(provider.supportedProfileDetailFields, [.email, .orgUUID])
    }

    func test_fetchUsage_success_buildsPrimaryAndSecondary() async throws {
        let body = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window":   { "used_percent": 27, "reset_at": "2026-05-25T18:22:00Z" },
            "secondary_window": { "used_percent": 46, "reset_at": "2026-05-29T09:15:00Z" }
          }
        }
        """
        let api = CodexAPIClient(transport: { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body.data(using: .utf8)!, resp)
        })
        let provider = makeProvider(
            apiClient: api,
            readerStub: StubCodexAuthReader(token: "acc")
        )
        let summary = try await provider.fetchUsage(
            credential: makeCredential(),
            profile: makeProfile()
        )
        XCTAssertEqual(summary.providerID, .codex)
        // utilization is 0-100 across the app (matches Claude pipeline +
        // UsageTrendChart formatter). Earlier divide-by-100 hid real usage
        // as "0% used" because Int(0.27) rounded to 0.
        XCTAssertEqual(summary.primary?.utilization, 27)
        XCTAssertEqual(summary.secondary?.utilization, 46)
        XCTAssertNotNil(summary.payload as? CodexUsageSnapshot)
    }

    func test_fetchUsage_401_thenForceRefreshRotation_retries() async throws {
        // First call 401; second call 200 (after the refresher rotates).
        var callCount = 0
        let body = """
        {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":11}}}
        """
        let api = CodexAPIClient(transport: { req in
            callCount += 1
            if callCount == 1 {
                let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body.data(using: .utf8)!, resp)
        })
        let provider = makeProvider(
            apiClient: api,
            readerStub: StubCodexAuthReader(token: "rotated")  // different from "acc"
        )
        let summary = try await provider.fetchUsage(
            credential: makeCredential(),
            profile: makeProfile()
        )
        XCTAssertEqual(callCount, 2, "401 must trigger one retry after forceRefresh")
        XCTAssertEqual(summary.primary?.utilization, 11)
    }

    func test_fetchUsage_401_andNoRotation_surfacesUnauthorized() async {
        let api = CodexAPIClient(transport: { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        })
        let provider = makeProvider(
            apiClient: api,
            readerStub: StubCodexAuthReader(token: "acc")  // SAME as failing credential
        )
        do {
            _ = try await provider.fetchUsage(
                credential: makeCredential(),
                profile: makeProfile()
            )
            XCTFail("Expected unauthorized")
        } catch ClaudeAPIClient.APIError.unauthorized {
            // pass
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Identity guard (CLI account switch race)

    func test_fetchUsage_identityMismatch_throwsBeforeNetworkCall() async {
        // The on-disk CLI is signed in as a DIFFERENT account than the
        // profile we're refreshing. fetchUsage must refuse and not issue
        // any HTTP request.
        var httpCalls = 0
        let api = CodexAPIClient(transport: { _ in
            httpCalls += 1
            let resp = HTTPURLResponse(
                url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data("{}".utf8), resp)
        })
        let provider = makeProvider(
            apiClient: api,
            readerStub: StubCodexAuthReader(token: "acc", email: "other@x.com")
        )
        do {
            _ = try await provider.fetchUsage(
                credential: makeCredential(),
                profile: makeProfile()   // email = "u@x.com"
            )
            XCTFail("Expected IdentityMismatchError")
        } catch let err as CodexProvider.IdentityMismatchError {
            XCTAssertEqual(err.profileEmail, "u@x.com")
            XCTAssertEqual(err.onDiskEmail, "other@x.com")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        XCTAssertEqual(httpCalls, 0, "Identity guard must short-circuit before the network")
    }

    func test_fetchUsage_identityMatchCaseInsensitively_proceeds() async throws {
        let body = """
        {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":3}}}
        """
        let api = CodexAPIClient(transport: { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body.data(using: .utf8)!, resp)
        })
        // On-disk email differs from profile.email ONLY in case ("U@X.COM" vs
        // "u@x.com"). Must be treated as the same account, matching the rest
        // of the codebase (caseInsensitiveCompare via ProfileSwitcherCard,
        // ProfileStore.findMatching, AutoProfileCoordinator).
        let provider = makeProvider(
            apiClient: api,
            readerStub: StubCodexAuthReader(token: "acc", email: "U@X.COM")
        )
        let summary = try await provider.fetchUsage(
            credential: makeCredential(),
            profile: makeProfile()
        )
        XCTAssertEqual(summary.primary?.utilization, 3)
    }

    func test_fetchUsage_nilOnDiskIdentity_throwsMismatch() async {
        // Token present but email nil (e.g. an id_token JWT that didn't
        // include the email claim). Treat as "can't verify identity" →
        // mismatch, no fetch. Safer than running with an unknowable account.
        let provider = makeProvider(
            apiClient: CodexAPIClient(transport: { _ in
                XCTFail("Network must not be reached")
                return (Data(), HTTPURLResponse())
            }),
            readerStub: StubCodexAuthReader(token: "acc", email: nil)
        )
        do {
            _ = try await provider.fetchUsage(
                credential: makeCredential(),
                profile: makeProfile()
            )
            XCTFail("Expected IdentityMismatchError")
        } catch let err as CodexProvider.IdentityMismatchError {
            XCTAssertEqual(err.profileEmail, "u@x.com")
            XCTAssertNil(err.onDiskEmail)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - refreshProfileMetadata

    private func usageAPI(usedPercent: Int = 5) -> CodexAPIClient {
        let body = "{\"plan_type\":\"plus\",\"rate_limit\":{\"primary_window\":{\"used_percent\":\(usedPercent)}}}"
        return CodexAPIClient(transport: { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body.data(using: .utf8)!, resp)
        })
    }

    func test_refreshProfileMetadata_reconcilesOrgAndName_returnsTrue() async throws {
        var profile = makeProfile()        // org nil, name "Codex"
        try profileStore.add(profile)
        let provider = makeProvider(
            apiClient: usageAPI(),
            readerStub: StubCodexAuthReader(token: "acc", accountId: "acct-1", name: "New Name")
        )
        let changed = try await provider.refreshProfileMetadata(
            for: profile, credential: makeCredential())
        XCTAssertTrue(changed)
        let stored = profileStore.profiles.first(where: { $0.id == profile.id })!
        XCTAssertEqual(stored.organizationId, "acct-1")
        XCTAssertEqual(stored.name, "New Name")
        _ = profile
    }

    func test_refreshProfileMetadata_allFieldsMatch_returnsFalse() async throws {
        var profile = makeProfile()
        profile.organizationId = "acct-1"
        profile.name = "Same"
        try profileStore.add(profile)
        let provider = makeProvider(
            apiClient: usageAPI(),
            readerStub: StubCodexAuthReader(token: "acc", accountId: "acct-1", name: "Same")
        )
        let changed = try await provider.refreshProfileMetadata(
            for: profile, credential: makeCredential())
        XCTAssertFalse(changed)
    }

    func test_refreshProfileMetadata_emailMismatch_throwsIdentityMismatch() async throws {
        let profile = makeProfile()        // email u@x.com
        try profileStore.add(profile)
        let provider = makeProvider(
            apiClient: usageAPI(),
            readerStub: StubCodexAuthReader(token: "acc", email: "other@x.com")
        )
        do {
            _ = try await provider.refreshProfileMetadata(for: profile, credential: makeCredential())
            XCTFail("expected identityMismatch")
        } catch ProviderMetadataRefreshError.identityMismatch {
            // pass
        }
    }

    func test_refreshProfileMetadata_noOnDiskAuth_throwsUnauthorized() async throws {
        let profile = makeProfile()
        try profileStore.add(profile)
        let provider = makeProvider(
            apiClient: usageAPI(),
            readerStub: StubCodexAuthReader(token: nil)   // signed out
        )
        do {
            _ = try await provider.refreshProfileMetadata(for: profile, credential: makeCredential())
            XCTFail("expected unauthorized")
        } catch ProviderMetadataRefreshError.unauthorized {
            // pass
        }
    }

    func test_refreshProfileMetadata_fetchUsage401_throwsUnauthorized() async throws {
        let profile = makeProfile()
        try profileStore.add(profile)
        let api = CodexAPIClient(transport: { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        })
        let provider = makeProvider(
            apiClient: api,
            readerStub: StubCodexAuthReader(token: "acc")  // same token → no rotation
        )
        do {
            _ = try await provider.refreshProfileMetadata(for: profile, credential: makeCredential())
            XCTFail("expected unauthorized")
        } catch ProviderMetadataRefreshError.unauthorized {
            // pass
        }
    }
}

private struct StubCodexAuthReader: CodexAuthReaderProviding {
    let token: String?
    let email: String?
    let accountId: String?
    let name: String?
    let subscriptionActiveUntil: Date?
    init(
        token: String?,
        email: String? = "u@x.com",
        accountId: String? = nil,
        name: String? = nil,
        subscriptionActiveUntil: Date? = nil
    ) {
        self.token = token
        self.email = email
        self.accountId = accountId
        self.name = name
        self.subscriptionActiveUntil = subscriptionActiveUntil
    }
    func read() -> CodexAuthReader.Auth? {
        guard let token, !token.isEmpty else { return nil }
        return CodexAuthReader.Auth(
            accessToken: token,
            refreshToken: "r",
            idToken: nil,
            accountId: accountId,
            email: email,
            name: name,
            subscriptionActiveUntil: subscriptionActiveUntil
        )
    }
}
