//
//  CaffeinateOptionsTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class CaffeinateOptionsTests: XCTestCase {

    /// Profiles persisted by older Kwota versions include the now-removed
    /// `preventDiskSleep` key. The new struct must decode such payloads
    /// cleanly, silently ignoring the extra key.
    func test_legacyDecodeIgnoresPreventDiskSleep() throws {
        let json = Data("""
        {
            "preventDisplaySleep": true,
            "preventIdleSleep": true,
            "preventDiskSleep": true,
            "preventSystemSleep": true,
            "declareUserActivity": true,
            "timeoutSeconds": 1800
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(CaffeinateOptions.self, from: json)

        XCTAssertTrue(decoded.preventDisplaySleep)
        XCTAssertTrue(decoded.preventIdleSleep)
        XCTAssertTrue(decoded.preventSystemSleep)
        XCTAssertTrue(decoded.declareUserActivity)
        XCTAssertEqual(decoded.timeoutSeconds, 1800)
    }
}
