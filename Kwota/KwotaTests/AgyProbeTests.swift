//
//  AgyProbeTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class AgyProbeTests: XCTestCase {
    func testRunReturnsBareVersionVerbatim() async throws {
        let mock = MockProcessLauncher()
        mock.runResult = ProcessResult(stdout: "1.0.2\n", stderr: "", exitCode: 0)
        let probe = AgyProbe(launcher: mock)

        let result = try await probe.run()

        XCTAssertEqual(result.version, "1.0.2")
        XCTAssertNil(result.error)
        XCTAssertEqual(mock.invocations.count, 1)
        let inv = mock.invocations[0]
        XCTAssertEqual(inv.executable, "/usr/bin/env")
        XCTAssertEqual(inv.arguments[0], "-S")
        XCTAssertTrue(inv.arguments[1].hasPrefix("PATH="))
        XCTAssertTrue(inv.arguments[1].contains("/opt/homebrew/bin"))
        XCTAssertEqual(inv.arguments[2], "agy")
        XCTAssertEqual(inv.arguments[3], "--version")
    }

    func testRunStripsPrefixWhenPresent() async throws {
        let mock = MockProcessLauncher()
        mock.runResult = ProcessResult(stdout: "agy 1.0.2\n", stderr: "", exitCode: 0)
        let probe = AgyProbe(launcher: mock)

        let result = try await probe.run()

        XCTAssertEqual(result.version, "1.0.2")
        XCTAssertNil(result.error)
    }

    func testRunReportsErrorWhenExitNonZero() async throws {
        let mock = MockProcessLauncher()
        mock.runResult = ProcessResult(
            stdout: "", stderr: "env: agy: No such file or directory\n", exitCode: 127)
        let probe = AgyProbe(launcher: mock)

        let result = try await probe.run()

        XCTAssertNil(result.version)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("No such file"))
    }
}
