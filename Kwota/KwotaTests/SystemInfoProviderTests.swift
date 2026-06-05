//
//  SystemInfoProviderTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class SystemInfoProviderTests: XCTestCase {
    func test_macOSVersionString_formatsTriplet() {
        let v = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 1)
        XCTAssertEqual(SystemInfoProvider.macOSVersionString(from: v), "14.5.1")
    }

    func test_macOSVersionString_zeroPatchStillFormatted() {
        let v = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        XCTAssertEqual(SystemInfoProvider.macOSVersionString(from: v), "15.0.0")
    }
}
