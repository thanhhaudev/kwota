//
//  ProfileDetailFormatterTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class ProfileDetailFormatterTests: XCTestCase {

    // MARK: - subscriptionStatus

    func test_subscriptionStatus_active()     { XCTAssertEqual(ProfileDetailFormatter.subscriptionStatus("active"), "Active") }
    func test_subscriptionStatus_trial()      { XCTAssertEqual(ProfileDetailFormatter.subscriptionStatus("trial"), "Trial") }
    func test_subscriptionStatus_canceled()   { XCTAssertEqual(ProfileDetailFormatter.subscriptionStatus("canceled"), "Canceled") }
    func test_subscriptionStatus_incomplete() { XCTAssertEqual(ProfileDetailFormatter.subscriptionStatus("incomplete"), "Incomplete") }
    func test_subscriptionStatus_nil()        { XCTAssertEqual(ProfileDetailFormatter.subscriptionStatus(nil), "—") }
    func test_subscriptionStatus_unknown()    { XCTAssertEqual(ProfileDetailFormatter.subscriptionStatus("pending"), "Pending") }
    func test_subscriptionStatus_unknownUnderscored() {
        XCTAssertEqual(ProfileDetailFormatter.subscriptionStatus("past_due"), "Past due")
    }

    // MARK: - billingType

    func test_billingType_stripeSubscription() { XCTAssertEqual(ProfileDetailFormatter.billingType("stripe_subscription"), "Stripe subscription") }
    func test_billingType_nil()                { XCTAssertEqual(ProfileDetailFormatter.billingType(nil), "—") }
    func test_billingType_unknownUnderscored() { XCTAssertEqual(ProfileDetailFormatter.billingType("invoice_based"), "Invoice based") }

    // MARK: - hasExtraUsage

    func test_hasExtraUsage_true()  { XCTAssertEqual(ProfileDetailFormatter.hasExtraUsage(true), "Enabled") }
    func test_hasExtraUsage_false() { XCTAssertEqual(ProfileDetailFormatter.hasExtraUsage(false), "Disabled") }
    func test_hasExtraUsage_nil()   { XCTAssertEqual(ProfileDetailFormatter.hasExtraUsage(nil), "—") }

    // MARK: - uuidMasked

    func test_uuidMasked_lastTwelve() {
        XCTAssertEqual(
            ProfileDetailFormatter.uuidMasked("4970bd29-1771-42c1-8274-cced9e79d94c"),
            "••••cced9e79d94c"
        )
    }
    func test_uuidMasked_shortPassesThrough() {
        XCTAssertEqual(ProfileDetailFormatter.uuidMasked("abc"), "abc")
    }
    func test_uuidMasked_nil() {
        XCTAssertEqual(ProfileDetailFormatter.uuidMasked(nil), "—")
    }

    // MARK: - organizationNameMasked

    func test_organizationNameMasked_containsEmail() {
        XCTAssertEqual(
            ProfileDetailFormatter.organizationNameMasked("test@example.com's Organization"),
            "t••••@example.com's Organization"
        )
    }
    func test_organizationNameMasked_plainName() {
        XCTAssertEqual(
            ProfileDetailFormatter.organizationNameMasked("Acme Inc"),
            "Acme Inc"
        )
    }

    func test_organizationNameMasked_plainEmail() {
        // Regression: ProfileDetailView.displayedName falls back to
        // Profile.name when displayName is nil. For auto-created profiles
        // Profile.name == email, so the header would leak the raw email
        // in masked mode without this masking path. This test pins that
        // a bare email input gets the local-part masked the same way as
        // an email embedded in an org name.
        XCTAssertEqual(
            ProfileDetailFormatter.organizationNameMasked("h@gmail.com"),
            "h••••@gmail.com"
        )
    }
}
