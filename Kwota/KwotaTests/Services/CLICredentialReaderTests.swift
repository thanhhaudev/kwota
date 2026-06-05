//
//  CLICredentialReaderTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class CLICredentialReaderTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() {
        super.setUp()
        temp = TempDirectory()
    }

    func testIsAvailableFalseWhenNeitherSourceExists() {
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: { nil }
        )
        XCTAssertFalse(reader.isAvailable)
    }

    func testIsAvailableTrueWhenFileExists() throws {
        let url = temp.file("creds.json")
        try Data("{}".utf8).write(to: url)
        let reader = CLICredentialReader(credentialsFile: url, keychainProbe: { nil })
        XCTAssertTrue(reader.isAvailable)
    }

    func testIsAvailableFalseWhenOnlyKeychainHasPayload() {
        // isAvailable is file-only — a Keychain payload alone does not count.
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: { Data("{}".utf8) }
        )
        XCTAssertFalse(reader.isAvailable)
    }

    func test_isAvailable_doesNotProbeKeychain() {
        var probed = false
        let reader = CLICredentialReader(
            credentialsFile: URL(fileURLWithPath: "/nonexistent/.credentials.json"),
            keychainProbe: { probed = true; return Data("x".utf8) }
        )
        _ = reader.isAvailable
        XCTAssertFalse(probed, "isAvailable must not read the Keychain")
        XCTAssertFalse(reader.isAvailable, "no file present → not available")
    }

    func testReadFromFileReturnsCLIToken() throws {
        let url = temp.file("creds.json")
        let json = #"""
        {"accessToken":"a-token","refreshToken":"r-token","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        try Data(json.utf8).write(to: url)
        let reader = CLICredentialReader(credentialsFile: url, keychainProbe: { nil })
        let result = try reader.read()
        guard case .cliToken(let access, let refresh, let expires) = result.credential else {
            return XCTFail("expected cliToken")
        }
        XCTAssertEqual(access, "a-token")
        XCTAssertEqual(refresh, "r-token")
        XCTAssertEqual(expires, ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
        XCTAssertNil(result.subscriptionPlan)
    }

    func testReadFromKeychainEnvelopePrefersKeychainOverFile() throws {
        let url = temp.file("creds.json")
        let fileJSON = #"""
        {"accessToken":"file","refreshToken":"file","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        try Data(fileJSON.utf8).write(to: url)

        let kcJSON = #"""
        {"claudeAiOauth":{"accessToken":"kc","refreshToken":"kc-r","expiresAt":1893456000000,"subscriptionType":"max"}}
        """#
        let reader = CLICredentialReader(
            credentialsFile: url,
            keychainProbe: { Data(kcJSON.utf8) }
        )
        let result = try reader.read()
        guard case .cliToken(let access, _, _) = result.credential else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "kc")
        XCTAssertEqual(result.subscriptionPlan, "max")
    }

    func testReadFromKeychainFlatPayload() throws {
        let kcJSON = #"""
        {"accessToken":"flat","refreshToken":"r","expiresAt":"2030-01-01T00:00:00Z"}
        """#
        let reader = CLICredentialReader(
            credentialsFile: temp.file("missing.json"),
            keychainProbe: { Data(kcJSON.utf8) }
        )
        let result = try reader.read()
        guard case .cliToken(let access, _, _) = result.credential else { return XCTFail("expected cliToken") }
        XCTAssertEqual(access, "flat")
    }

    func testReadThrowsWhenFileMalformedAndKeychainEmpty() throws {
        let url = temp.file("creds.json")
        try Data("not json".utf8).write(to: url)
        let reader = CLICredentialReader(credentialsFile: url, keychainProbe: { nil })
        XCTAssertThrowsError(try reader.read())
    }
}
