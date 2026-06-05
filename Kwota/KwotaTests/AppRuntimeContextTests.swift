//
//  AppRuntimeContextTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class AppRuntimeContextTests: XCTestCase {
    func testDetect_returnsNormalApp_withoutHostedTestMarkers() {
        XCTAssertEqual(
            AppRuntimeContext.detect(environment: [:], hasXCTestClass: false),
            .normalApp
        )
    }

    func testDetect_returnsHostedTests_whenXCTestEnvironmentMarkerPresent() {
        XCTAssertEqual(
            AppRuntimeContext.detect(
                environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
                hasXCTestClass: false
            ),
            .hostedTests
        )
    }

    func testDetect_returnsHostedTests_whenXCTestClassIsLoaded() {
        XCTAssertEqual(
            AppRuntimeContext.detect(environment: [:], hasXCTestClass: true),
            .hostedTests
        )
    }
}
