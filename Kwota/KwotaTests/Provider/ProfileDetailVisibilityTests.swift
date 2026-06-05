//
//  ProfileDetailVisibilityTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class ProfileDetailVisibilityTests: XCTestCase {
    func testFullSetShowsEverything() {
        let v = ProfileDetailVisibility(fields: Set(ProfileDetailField.allCases))
        XCTAssertTrue(v.showsEmail)
        XCTAssertTrue(v.showsAccountCreated)
        XCTAssertTrue(v.showsSubscriptionSection)
        XCTAssertTrue(v.showsPlan)
        XCTAssertTrue(v.showsBilling)
        XCTAssertTrue(v.showsExtraUsage)
        XCTAssertTrue(v.showsOrganizationSection)
        XCTAssertTrue(v.showsAccountUUID)
        XCTAssertTrue(v.showsOrgUUID)
    }

    func testAntigravityShapeShowsPlanOnlyInSubscription() {
        let v = ProfileDetailVisibility(fields: [.email, .plan])
        XCTAssertTrue(v.showsEmail)
        XCTAssertTrue(v.showsPlan)
        XCTAssertTrue(v.showsSubscriptionSection)   // plan keeps the section
        XCTAssertFalse(v.showsBilling)
        XCTAssertFalse(v.showsSubscriptionStatus)
        XCTAssertFalse(v.showsOrganizationSection)
        XCTAssertFalse(v.showsAccountUUID)
        XCTAssertFalse(v.showsOrgUUID)
        XCTAssertFalse(v.showsAccountCreated)
    }

    func testCodexShapeHidesSubscriptionSection() {
        let v = ProfileDetailVisibility(fields: [.email, .orgUUID])
        XCTAssertTrue(v.showsEmail)
        XCTAssertTrue(v.showsOrgUUID)
        XCTAssertFalse(v.showsSubscriptionSection)  // no plan/status/etc → hidden
        XCTAssertFalse(v.showsPlan)
        XCTAssertFalse(v.showsOrganizationSection)
        XCTAssertFalse(v.showsAccountUUID)
    }

    func testEmptySetHidesAllSections() {
        let v = ProfileDetailVisibility(fields: [])
        XCTAssertFalse(v.showsSubscriptionSection)
        XCTAssertFalse(v.showsOrganizationSection)
        XCTAssertFalse(v.showsEmail)
    }
}
