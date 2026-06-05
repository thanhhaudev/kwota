//
//  PopoverPollingCadenceTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class PopoverPollingCadenceTests: XCTestCase {
    func test_defaultsToClosedInterval() {
        // The popover starts closed at launch, so idle work polls slowly.
        let cadence = PopoverPollingCadence(openInterval: 5, closedInterval: 60)
        XCTAssertEqual(cadence.currentInterval, 60)
    }

    func test_setOpen_switchesToOpen_andReportsChanged() {
        var cadence = PopoverPollingCadence(openInterval: 5, closedInterval: 60)
        XCTAssertTrue(cadence.setOpen(), "transition from closed → open is a change")
        XCTAssertEqual(cadence.currentInterval, 5)
    }

    func test_setOpen_whenAlreadyOpen_reportsNoChange() {
        var cadence = PopoverPollingCadence(openInterval: 5, closedInterval: 60)
        _ = cadence.setOpen()
        XCTAssertFalse(cadence.setOpen(), "already open → no reschedule needed")
        XCTAssertEqual(cadence.currentInterval, 5)
    }

    func test_setClosed_switchesBack_andReportsChanged() {
        var cadence = PopoverPollingCadence(openInterval: 5, closedInterval: 60)
        _ = cadence.setOpen()
        XCTAssertTrue(cadence.setClosed(), "open → closed is a change")
        XCTAssertEqual(cadence.currentInterval, 60)
        XCTAssertFalse(cadence.setClosed(), "already closed → no change")
    }

    func test_equalOpenAndClosed_neverReportsChange() {
        // Test fixtures pass equal intervals; flipping state must stay a no-op
        // so they don't thrash their scheduler.
        var cadence = PopoverPollingCadence(openInterval: 0.05, closedInterval: 0.05)
        XCTAssertFalse(cadence.setOpen())
        XCTAssertFalse(cadence.setClosed())
        XCTAssertEqual(cadence.currentInterval, 0.05)
    }
}
