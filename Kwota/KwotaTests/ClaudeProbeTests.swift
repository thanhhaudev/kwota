//
//  ClaudeProbeTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class ClaudeProbeTests: XCTestCase {
    func testAugmentedPATHPutsHomebrewAndUsrLocalFirstWithoutDuplicates() {
        let path = ClaudeProbe.augmentedPATH(existing: "/usr/bin:/bin:/opt/homebrew/bin")
        let parts = path.split(separator: ":").map(String.init)
        XCTAssertEqual(parts.first, "/opt/homebrew/bin")
        XCTAssertTrue(parts.contains("/usr/local/bin"))
        XCTAssertTrue(parts.contains("/usr/bin"))
        XCTAssertEqual(parts.count, Set(parts).count, "no duplicates")
    }

    func testRunStripsClaudeCodeSuffix() async throws {
        let mock = MockProcessLauncher()
        mock.runResult = ProcessResult(stdout: "1.4.2 (Claude Code)\n", stderr: "", exitCode: 0)
        let probe = ClaudeProbe(launcher: mock)

        let result = try await probe.run()

        XCTAssertEqual(result.version, "1.4.2")
        XCTAssertNil(result.error)
        XCTAssertEqual(mock.invocations.count, 1)
        let inv = mock.invocations[0]
        XCTAssertEqual(inv.executable, "/usr/bin/env")
        XCTAssertEqual(inv.arguments[0], "-S")
        XCTAssertTrue(inv.arguments[1].hasPrefix("PATH="))
        XCTAssertTrue(inv.arguments[1].contains("/opt/homebrew/bin"))
        XCTAssertEqual(inv.arguments[2], "claude")
        XCTAssertEqual(inv.arguments[3], "--version")
    }

    func testRunPassesThroughBareVersion() async throws {
        let mock = MockProcessLauncher()
        mock.runResult = ProcessResult(stdout: "2.1.133\n", stderr: "", exitCode: 0)
        let probe = ClaudeProbe(launcher: mock)

        let result = try await probe.run()

        XCTAssertEqual(result.version, "2.1.133")
        XCTAssertNil(result.error)
    }

    func testRunReportsErrorWhenExitNonZero() async throws {
        let mock = MockProcessLauncher()
        mock.runResult = ProcessResult(stdout: "", stderr: "env: claude: No such file or directory\n", exitCode: 127)
        let probe = ClaudeProbe(launcher: mock)

        let result = try await probe.run()

        XCTAssertNil(result.version)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("No such file"))
    }
}
