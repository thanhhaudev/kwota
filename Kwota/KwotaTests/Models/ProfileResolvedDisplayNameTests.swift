//
//  ProfileResolvedDisplayNameTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class ProfileResolvedDisplayNameTests: XCTestCase {
    func test_prefersDisplayName_whenPresent() {
        var p = Profile(name: "row-label", authMethod: .cliSync)
        p.displayName = "API Name"
        XCTAssertEqual(p.resolvedDisplayName, "API Name")
    }

    func test_fallsBackToName_whenDisplayNameNil() {
        let p = Profile(name: "row-label", authMethod: .cliSync)
        XCTAssertEqual(p.resolvedDisplayName, "row-label")
    }

    func test_fallsBackToName_whenDisplayNameEmpty() {
        var p = Profile(name: "row-label", authMethod: .cliSync)
        p.displayName = ""
        XCTAssertEqual(p.resolvedDisplayName, "row-label")
    }
}
