//
//  MenuBarViewModelSWRGateTests.swift
//  KwotaTests
//
//  Covers the pure stale-while-revalidate predicate that suppresses
//  popover-open refetches when the active summary is still fresh.
//

import XCTest
@testable import Kwota

final class MenuBarViewModelSWRGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let window: TimeInterval = 60

    func test_shouldSkipRefresh_returnsFalse_whenNoPriorFetch() {
        let skip = MenuBarViewModelSWRGate.shouldSkipRefresh(
            fetchedAt: nil,
            now: now,
            window: window,
            isManual: false
        )
        XCTAssertFalse(skip,
            "no prior fetch — opportunistic trigger must fall through to a real refresh")
    }

    func test_shouldSkipRefresh_returnsTrue_whenWithinWindowAndAuto() {
        let fresh = now.addingTimeInterval(-30)
        let skip = MenuBarViewModelSWRGate.shouldSkipRefresh(
            fetchedAt: fresh,
            now: now,
            window: window,
            isManual: false
        )
        XCTAssertTrue(skip,
            "30s-old summary inside the 60s window — opportunistic refetch must be skipped")
    }

    func test_shouldSkipRefresh_returnsFalse_whenOutsideWindow() {
        let stale = now.addingTimeInterval(-90)
        let skip = MenuBarViewModelSWRGate.shouldSkipRefresh(
            fetchedAt: stale,
            now: now,
            window: window,
            isManual: false
        )
        XCTAssertFalse(skip,
            "90s-old summary outside the 60s window — must refresh")
    }

    func test_shouldSkipRefresh_returnsFalse_whenManualEvenIfFresh() {
        let fresh = now.addingTimeInterval(-5)
        let skip = MenuBarViewModelSWRGate.shouldSkipRefresh(
            fetchedAt: fresh,
            now: now,
            window: window,
            isManual: true
        )
        XCTAssertFalse(skip,
            "manual Refresh tap must always refresh, even inside the freshness window")
    }

    func test_shouldSkipRefresh_boundaryEdge_atExactlyWindow() {
        // Boundary: a summary exactly `window` seconds old is on the edge.
        // We define the predicate as strict < (skip only when *inside* the
        // window), so an exact-boundary value must NOT skip.
        let exact = now.addingTimeInterval(-window)
        let skip = MenuBarViewModelSWRGate.shouldSkipRefresh(
            fetchedAt: exact,
            now: now,
            window: window,
            isManual: false
        )
        XCTAssertFalse(skip,
            "a summary exactly `window` seconds old is on the boundary — must refresh")
    }
}
