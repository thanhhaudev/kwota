//  ProfileObservedCreditResetTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

final class ProfileObservedCreditResetTests: XCTestCase {
    func test_roundTripsThroughJSON() throws {
        var p = Profile(name: "agy", authMethod: .cliSync, providerID: .antigravity)
        p.observedCreditResetAt = Date(timeIntervalSince1970: 1_700_000_000)
        p.lastCreditWallet = 250
        p.lastCreditCeiling = 1000
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(back.observedCreditResetAt, p.observedCreditResetAt)
        XCTAssertEqual(back.lastCreditWallet, 250)
        XCTAssertEqual(back.lastCreditCeiling, 1000)
    }

    func test_absentInOldJSON_decodesToNil() throws {
        // Minimal legacy JSON without the new keys.
        let json = """
        {"id":"\(UUID().uuidString)","name":"old","authMethod":"cliSync"}
        """.data(using: .utf8)!
        let back = try JSONDecoder().decode(Profile.self, from: json)
        XCTAssertNil(back.observedCreditResetAt)
        XCTAssertNil(back.lastCreditWallet)
        XCTAssertNil(back.lastCreditCeiling)
    }
}
