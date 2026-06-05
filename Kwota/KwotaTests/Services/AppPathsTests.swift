//
//  AppPathsTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class AppPathsTests: XCTestCase {
    func testApplicationSupportDirectoryEndsWithBundleId() {
        let url = AppPaths.applicationSupportDirectory
        XCTAssertEqual(url.lastPathComponent, "com.thanhhaudev.Kwota")
    }

    func testProfilesJSONFileSitsInsideAppSupport() {
        XCTAssertEqual(AppPaths.profilesFile.lastPathComponent, "profiles.json")
        XCTAssertEqual(AppPaths.profilesFile.deletingLastPathComponent(),
                       AppPaths.applicationSupportDirectory)
    }

    func testProfileDirectoryNamespacesByUUID() {
        let id = UUID()
        let dir = AppPaths.profileDirectory(id: id)
        XCTAssertEqual(dir.lastPathComponent, id.uuidString)
        XCTAssertEqual(dir.deletingLastPathComponent().lastPathComponent, "profiles")
    }

    func testHistoryFilename() {
        let id = UUID()
        XCTAssertEqual(AppPaths.usageHistoryFile(id: id).lastPathComponent, "usage-history.json")
    }
}
