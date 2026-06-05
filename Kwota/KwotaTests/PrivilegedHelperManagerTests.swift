//
//  PrivilegedHelperManagerTests.swift
//  KwotaTests
//

import XCTest
import ServiceManagement
@testable import Kwota

@MainActor
final class PrivilegedHelperManagerTests: XCTestCase {

    // MARK: - resolveStatus (pure)

    func testResolveStatusMapsServiceStates() {
        XCTAssertEqual(
            PrivilegedHelperManager.resolveStatus(service: .notRegistered, helperVersion: nil),
            .notInstalled)
        XCTAssertEqual(
            PrivilegedHelperManager.resolveStatus(service: .notFound, helperVersion: nil),
            .notInstalled)
        XCTAssertEqual(
            PrivilegedHelperManager.resolveStatus(service: .requiresApproval, helperVersion: nil),
            .requiresApproval)
        XCTAssertEqual(
            PrivilegedHelperManager.resolveStatus(service: .enabled, helperVersion: KwotaHelperInfo.version),
            .enabled)
    }

    func testEnabledButStaleHelperResolvesToNeedsUpdate() {
        XCTAssertEqual(
            PrivilegedHelperManager.resolveStatus(service: .enabled, helperVersion: "0"),
            .needsUpdate)
    }

    func testEnabledWithUnknownVersionIsTreatedAsEnabled() {
        XCTAssertEqual(
            PrivilegedHelperManager.resolveStatus(service: .enabled, helperVersion: nil),
            .enabled)
    }

    // MARK: - refreshStatus

    func testRefreshStatusReadsTheServiceAndConnector() async {
        let service = FakeSystemService(status: .enabled)
        let connector = FakeHelperConnector(version: KwotaHelperInfo.version)
        let manager = PrivilegedHelperManager(service: service, connector: connector)

        await manager.refreshStatus()
        XCTAssertEqual(manager.status, .enabled)
    }

    func testRefreshStatusDetectsStaleHelper() async {
        let service = FakeSystemService(status: .enabled)
        let connector = FakeHelperConnector(version: "0")
        let manager = PrivilegedHelperManager(service: service, connector: connector)

        await manager.refreshStatus()
        XCTAssertEqual(manager.status, .needsUpdate)
    }

    // MARK: - install / uninstall

    func testInstallRegistersAndRefreshes() async {
        let service = FakeSystemService(status: .notRegistered)
        let connector = FakeHelperConnector(version: KwotaHelperInfo.version)
        let manager = PrivilegedHelperManager(service: service, connector: connector)

        await manager.install()
        XCTAssertTrue(service.didRegister)
        XCTAssertEqual(manager.status, .enabled)
    }

    func testUpdateReloadsViaUnregisterThenRegister() async {
        // An out-of-date but reachable daemon: a bare register() would not
        // restart the running process, so update() must unregister (terminate)
        // then register (relaunch the current binary).
        let service = FakeSystemService(status: .enabled)
        let connector = FakeHelperConnector(version: KwotaHelperInfo.version)
        let manager = PrivilegedHelperManager(service: service, connector: connector)

        await manager.update()
        XCTAssertTrue(service.didUnregister, "must terminate the stale daemon first")
        XCTAssertTrue(service.didRegister, "must relaunch the current binary")
        XCTAssertEqual(manager.status, .enabled)
    }

    func testUninstallUnregistersAndRefreshes() async {
        let service = FakeSystemService(status: .enabled)
        let connector = FakeHelperConnector(version: KwotaHelperInfo.version)
        let manager = PrivilegedHelperManager(service: service, connector: connector)

        await manager.uninstall()
        XCTAssertTrue(service.didUnregister)
        XCTAssertEqual(manager.status, .notInstalled)
    }

    // MARK: - cleanSystemCaches

    func testCleanRoutesThroughConnectorWhenEnabled() async {
        let service = FakeSystemService(status: .enabled)
        let connector = FakeHelperConnector(version: KwotaHelperInfo.version)
        connector.cleanResult = .success(SystemCleanOutcome(itemsRemoved: 3, bytesFreed: 99))
        let manager = PrivilegedHelperManager(service: service, connector: connector)
        await manager.refreshStatus()

        let result = await manager.cleanSystemCaches(identifiers: ["iconservices"])
        XCTAssertEqual(result, .success(SystemCleanOutcome(itemsRemoved: 3, bytesFreed: 99)))
        XCTAssertEqual(connector.cleanCallCount, 1)
    }

    func testCleanFailsFastWhenHelperNotEnabled() async {
        let service = FakeSystemService(status: .notRegistered)
        let connector = FakeHelperConnector(version: nil)
        let manager = PrivilegedHelperManager(service: service, connector: connector)
        await manager.refreshStatus()

        let result = await manager.cleanSystemCaches(identifiers: ["iconservices"])
        XCTAssertEqual(result, .failure(.helperUnavailable))
        XCTAssertEqual(connector.cleanCallCount, 0, "must not reach the connector when not enabled")
    }
}

// MARK: - Fakes

@MainActor
final class FakeSystemService: SystemServiceRegistering {
    var status: SMAppService.Status
    var didRegister = false
    var didUnregister = false

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        didRegister = true
        status = .enabled
    }
    func unregister() throws {
        didUnregister = true
        status = .notRegistered
    }
}

@MainActor
final class FakeHelperConnector: HelperConnecting {
    var version: String?
    var cleanResult: Result<SystemCleanOutcome, PrivilegedHelperError> =
        .success(SystemCleanOutcome(itemsRemoved: 0, bytesFreed: 0))
    var cleanCallCount = 0

    init(version: String?) { self.version = version }

    func helperVersion() async -> String? { version }

    func cleanSystemCaches(
        identifiers: [String]
    ) async -> Result<SystemCleanOutcome, PrivilegedHelperError> {
        cleanCallCount += 1
        return cleanResult
    }

    func systemCacheSizes(identifiers: [String]) async -> [String: Int64] { [:] }
}
