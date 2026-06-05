//  ProfileSwitcherSubtitleTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

@MainActor
final class ProfileSwitcherSubtitleTests: XCTestCase {
    func test_subtitle_combinesPlanAndEstimateDate() {
        let s = ProfileSwitcherCard.makeSubtitle(
            plan: "Google AI Pro",
            datePart: "Est. resets 18 Jun 2026",
            email: "a@b.com", displayName: "A")
        XCTAssertEqual(s, "Google AI Pro · Est. resets 18 Jun 2026")
    }

    func test_subtitle_planOnly_whenNoDate() {
        let s = ProfileSwitcherCard.makeSubtitle(
            plan: "Google AI Pro", datePart: nil,
            email: "a@b.com", displayName: "A")
        XCTAssertEqual(s, "Google AI Pro")
    }

    func test_subtitle_dateOnly_whenNoPlan() {
        let s = ProfileSwitcherCard.makeSubtitle(
            plan: nil, datePart: "Est. 6 Jun 2026",
            email: "a@b.com", displayName: "A")
        XCTAssertEqual(s, "Est. 6 Jun 2026")
    }
}
