//
//  ProviderRegistryTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class ProviderRegistryTests: XCTestCase {
    private func makeCLIReader() -> CLICredentialReader {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwota-tests-\(UUID().uuidString)")
            .appendingPathComponent("missing-credentials.json")
        return CLICredentialReader(credentialsFile: file, keychainProbe: { nil })
    }

    private func makeAccountReader() -> OAuthAccountReader {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwota-tests-\(UUID().uuidString)")
            .appendingPathComponent(".claude.json")
        return OAuthAccountReader(configFile: file, provider: { nil })
    }

    func testRegisterAndLookup() {
        let registry = ProviderRegistry()
        let claude = makeClaudeProvider()
        registry.register(claude)
        XCTAssertTrue(registry.provider(for: .claude) === claude)
        // Known provider that was never registered must still resolve to nil.
        XCTAssertNil(registry.provider(for: .codex))
    }

    func testAllReturnsRegisteredInInsertionOrder() {
        let registry = ProviderRegistry()
        let claude = makeClaudeProvider()
        registry.register(claude)
        XCTAssertEqual(registry.all.map(\.id), [.claude])
    }

    func testReRegisteringSameIDReplacesInPlace() {
        let registry = ProviderRegistry()
        let first = makeClaudeProvider()
        let second = makeClaudeProvider()
        registry.register(first)
        registry.register(second)
        XCTAssertEqual(registry.all.count, 1)
        XCTAssertTrue(registry.provider(for: .claude) === second)
    }

    private func makeClaudeProvider() -> ClaudeProvider {
        let store = KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwota-tests-\(UUID().uuidString)", isDirectory: true)
        let profileStore = ProfileStore(
            profilesFile: temp.appendingPathComponent("profiles.json"),
            keychain: store,
            profileDirectoryProvider: { temp.appendingPathComponent($0.uuidString) }
        )
        return ClaudeProvider(
            apiClient: ClaudeAPIClient(transport: { _ in throw URLError(.unknown) }),
            cliReader: makeCLIReader(),
            cliRefresher: CLITokenRefresher(store: store),
            accountReader: makeAccountReader(),
            profileFetcher: OAuthProfileFetcher(transport: { _ in throw URLError(.unknown) }),
            profileStore: profileStore
        )
    }
}
