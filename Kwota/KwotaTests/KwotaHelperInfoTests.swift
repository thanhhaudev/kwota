//
//  KwotaHelperInfoTests.swift
//  KwotaTests
//

import XCTest
import Security
@testable import Kwota

final class KwotaHelperInfoTests: XCTestCase {
    func test_appCodeRequirement_interpolatesTeam() {
        let req = KwotaHelperInfo.appCodeRequirement(team: "TEAM123")
        XCTAssertEqual(req,
            "anchor apple generic and identifier \"com.thanhhaudev.Kwota\" and certificate leaf[subject.OU] = \"TEAM123\"")
    }

    func test_helperCodeRequirement_interpolatesTeam() {
        // The helper is a command-line tool, so its code-signing identifier is
        // its product name (`KwotaPrivilegedHelper`), NOT the Mach service name.
        // The requirement must pin that exact identifier or the app rejects the
        // real helper.
        let req = KwotaHelperInfo.helperCodeRequirement(team: "TEAM123")
        XCTAssertEqual(req,
            "anchor apple generic and identifier \"KwotaPrivilegedHelper\" and certificate leaf[subject.OU] = \"TEAM123\"")
    }

    /// Integration guard: the *built* helper binary must actually satisfy the
    /// requirement the app applies to it. This is the check that was missing —
    /// `helperCodeRequirement` had pinned the Mach-service name instead of the
    /// helper's real (product-name) signing identifier, so the string-only test
    /// above passed while the runtime XPC connection was silently rejected.
    /// Reads the helper's own team so it works for any build-from-source signer;
    /// skips when no signed helper is present (e.g. unsigned/ad-hoc CI).
    func test_builtHelper_satisfiesHelperCodeRequirement() throws {
        let helperURL = Bundle(for: Self.self).bundleURL  // …/Kwota.app/Contents/PlugIns/KwotaTests.xctest
            .deletingLastPathComponent()                  // …/Contents/PlugIns
            .deletingLastPathComponent()                  // …/Contents
            .appendingPathComponent("MacOS/KwotaPrivilegedHelper")

        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw XCTSkip("Embedded helper not found at \(helperURL.path).")
        }

        var staticCode: SecStaticCode?
        XCTAssertEqual(
            SecStaticCodeCreateWithPath(helperURL as CFURL, SecCSFlags(), &staticCode),
            errSecSuccess, "could not read the helper's code signature")
        let code = try XCTUnwrap(staticCode)

        var infoCF: CFDictionary?
        XCTAssertEqual(
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF),
            errSecSuccess)
        let info = try XCTUnwrap(infoCF as? [String: Any])
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw XCTSkip("Helper has no team identifier (unsigned/ad-hoc build).")
        }

        var requirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString(
                KwotaHelperInfo.helperCodeRequirement(team: team) as CFString, SecCSFlags(), &requirement),
            errSecSuccess, "helperCodeRequirement did not compile as a SecRequirement")
        let req = try XCTUnwrap(requirement)

        XCTAssertEqual(
            SecStaticCodeCheckValidity(code, SecCSFlags(), req),
            errSecSuccess,
            "The built helper does NOT satisfy helperCodeRequirement → the app would reject its XPC "
            + "connection. The helper's code-sign identifier likely drifted from "
            + "\"\(KwotaHelperInfo.helperCodeSignIdentifier)\" (e.g. an embedded Info.plist changed it to "
            + "the bundle id).")
    }
}
