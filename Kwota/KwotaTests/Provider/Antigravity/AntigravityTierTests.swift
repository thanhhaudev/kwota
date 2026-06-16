import XCTest
@testable import Kwota

final class AntigravityTierTests: XCTestCase {
    // MARK: - detect()

    func test_detect_pro() {
        XCTAssertEqual(
            AntigravityTier.detect(userTierName: "Google AI Pro", monthlyPromptCredits: 50_000),
            .pro
        )
    }

    func test_detect_free() {
        XCTAssertEqual(
            AntigravityTier.detect(userTierName: "Google AI Free", monthlyPromptCredits: nil),
            .free
        )
    }

    func test_detect_ultra5x_belowBoundary() {
        // Ultra $100/mo: 5x Pro = ~250K; well below the 800K disambiguator.
        XCTAssertEqual(
            AntigravityTier.detect(userTierName: "Google AI Ultra", monthlyPromptCredits: 250_000),
            .ultra5x
        )
    }

    func test_detect_ultra20x_atOrAboveBoundary() {
        // Ultra $200/mo: 20x Pro = ~1M; well above the 800K disambiguator.
        XCTAssertEqual(
            AntigravityTier.detect(userTierName: "Google AI Ultra", monthlyPromptCredits: 1_000_000),
            .ultra20x
        )
        // Exact boundary value also classifies as 20x.
        XCTAssertEqual(
            AntigravityTier.detect(userTierName: "Google AI Ultra", monthlyPromptCredits: 800_000),
            .ultra20x
        )
    }

    func test_detect_ultraUnknownBaseline_defaultsTo5x() {
        // When name says Ultra but baseline is missing or zero, fall back
        // to 5x — both Ultra variants share the same AI Credits ceiling so
        // the choice only affects the badge label, not the bar math.
        XCTAssertEqual(
            AntigravityTier.detect(userTierName: "Google AI Ultra", monthlyPromptCredits: nil),
            .ultra5x
        )
        XCTAssertEqual(
            AntigravityTier.detect(userTierName: "Google AI Ultra", monthlyPromptCredits: 0),
            .ultra5x
        )
    }

    func test_detect_caseInsensitiveAndPartial() {
        // Detection matches by substring (case-insensitive) so future
        // wire renames like "google ai pro plus" still classify correctly.
        XCTAssertEqual(
            AntigravityTier.detect(userTierName: "GOOGLE AI PRO", monthlyPromptCredits: nil),
            .pro
        )
        XCTAssertEqual(
            AntigravityTier.detect(userTierName: "google ai pro plus", monthlyPromptCredits: nil),
            .pro
        )
    }

    func test_detect_unknown() {
        XCTAssertEqual(
            AntigravityTier.detect(userTierName: nil, monthlyPromptCredits: nil),
            .unknown
        )
        XCTAssertEqual(
            AntigravityTier.detect(userTierName: "", monthlyPromptCredits: nil),
            .unknown
        )
        XCTAssertEqual(
            AntigravityTier.detect(userTierName: "Some Future Tier", monthlyPromptCredits: nil),
            .unknown
        )
    }

    // MARK: - displayName

    func test_displayName_perCase() {
        XCTAssertEqual(AntigravityTier.free.displayName, "Free")
        XCTAssertEqual(AntigravityTier.pro.displayName, "Pro")
        XCTAssertEqual(AntigravityTier.ultra5x.displayName, "Ultra 5x")
        XCTAssertEqual(AntigravityTier.ultra20x.displayName, "Ultra 20x")
        XCTAssertNil(AntigravityTier.unknown.displayName)
    }

    // MARK: - aiCreditsCeiling

    func test_aiCreditsCeiling_perCase() {
        XCTAssertEqual(AntigravityTier.free.aiCreditsCeiling, 50)
        XCTAssertEqual(AntigravityTier.pro.aiCreditsCeiling, 1_000)
        XCTAssertEqual(AntigravityTier.ultra5x.aiCreditsCeiling, 25_000)
        XCTAssertEqual(AntigravityTier.ultra20x.aiCreditsCeiling, 25_000)
        XCTAssertNil(AntigravityTier.unknown.aiCreditsCeiling)
    }
}
