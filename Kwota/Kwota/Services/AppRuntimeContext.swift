//
//  AppRuntimeContext.swift
//  Kwota
//

import Foundation

enum AppRuntimeContext: Equatable {
    case normalApp
    case hostedTests

    static var current: AppRuntimeContext {
        detect(
            environment: ProcessInfo.processInfo.environment,
            hasXCTestClass: NSClassFromString("XCTestCase") != nil
        )
    }

    static func detect(
        environment: [String: String],
        hasXCTestClass: Bool
    ) -> AppRuntimeContext {
        if environment["XCTestConfigurationFilePath"] != nil || hasXCTestClass {
            return .hostedTests
        }
        return .normalApp
    }
}
