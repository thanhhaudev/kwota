//
//  ClaudeProviderTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class ClaudeProviderTests: XCTestCase {
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

    func testIDIsClaude() {
        let provider = makeProvider(transport: { _ in throw URLError(.unknown) })
        XCTAssertEqual(provider.id, .claude)
        XCTAssertEqual(provider.displayName, "Claude")
    }

    func testSupportedAuthMethodsAdvertisesOnlyCLI() {
        let provider = makeProvider(transport: { _ in throw URLError(.unknown) })
        let kinds = provider.supportedAuthMethods.map(\.kind)
        XCTAssertEqual(kinds, [.cliSync])
    }

    func testSupportedProfileDetailFieldsIsFullByDefault() {
        let provider = makeProvider(transport: { _ in throw URLError(.unknown) })
        XCTAssertEqual(provider.supportedProfileDetailFields,
                       Set(ProfileDetailField.allCases))
    }

    func test_reauthCopy_namesTheClaudeCLI() {
        let provider = makeProvider(transport: { _ in throw URLError(.unknown) })
        XCTAssertEqual(provider.reauthTitle, "Claude CLI session expired")
        XCTAssertTrue(provider.reauthInstruction.contains("claude login"),
                      "Claude re-auth detail must reference `claude login`")
    }

    private func makeProvider(transport: @escaping ClaudeAPIClient.Transport) -> ClaudeProvider {
        let service = "com.thanhhaudev.Kwota.test.\(UUID())"
        let store = KeychainCredentialStore(service: service)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwota-tests-\(UUID().uuidString)", isDirectory: true)
        let profileStore = ProfileStore(
            profilesFile: temp.appendingPathComponent("profiles.json"),
            keychain: store,
            profileDirectoryProvider: { temp.appendingPathComponent($0.uuidString) }
        )
        return ClaudeProvider(
            apiClient: ClaudeAPIClient(transport: transport),
            cliReader: makeCLIReader(),
            cliRefresher: CLITokenRefresher(store: store),
            accountReader: makeAccountReader(),
            profileFetcher: OAuthProfileFetcher(transport: { _ in throw URLError(.unknown) }),
            profileStore: profileStore
        )
    }
}
