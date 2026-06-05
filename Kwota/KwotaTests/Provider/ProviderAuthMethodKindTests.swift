//
//  ProviderAuthMethodKindTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class ProviderAuthMethodKindTests: XCTestCase {
    func testLegacyAuthMethodKindMapping() {
        XCTAssertEqual(ProviderAuthMethodKind(legacy: .cliSync), .cliSync)
        XCTAssertEqual(ProviderAuthMethodKind(legacy: .sessionKey), .sessionKey)
    }
}
