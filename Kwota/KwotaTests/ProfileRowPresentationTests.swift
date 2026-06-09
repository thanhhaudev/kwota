import XCTest
@testable import Kwota

@MainActor
final class ProfileRowPresentationTests: XCTestCase {

    // MARK: - displayName

    func testDisplayNameUsesEmailWhenUnmasked() {
        let p = Profile(name: "Auto Name", authMethod: .cliSync, email: "user@example.com")
        XCTAssertEqual(
            ProfileRowPresentation.displayName(p, privacyMasked: false),
            "user@example.com"
        )
    }

    func testDisplayNameMasksEmailWhenPrivacyOn() {
        let p = Profile(name: "Auto Name", authMethod: .cliSync, email: "thanhhaudev@gmail.com")
        XCTAssertEqual(
            ProfileRowPresentation.displayName(p, privacyMasked: true),
            "t••••@gmail.com"
        )
    }

    func testDisplayNameFallsBackToResolvedDisplayNameWhenNoEmail() {
        let p = Profile(name: "Row Name", authMethod: .cliSync, email: nil)
        XCTAssertEqual(
            ProfileRowPresentation.displayName(p, privacyMasked: false),
            "Row Name"
        )
        XCTAssertEqual(
            ProfileRowPresentation.displayName(p, privacyMasked: true),
            "Row Name"
        )
    }

    // MARK: - planSubtitle

    func testPlanSubtitleReturnsPlanWhenPresent() {
        var p = Profile(name: "Test", authMethod: .cliSync)
        p.subscriptionPlan = "Claude Pro"
        XCTAssertEqual(ProfileRowPresentation.planSubtitle(p, privacyMasked: false), "Claude Pro")
    }

    func testPlanSubtitleMasksWhenPrivacyOn() {
        var p = Profile(name: "Test", authMethod: .cliSync)
        p.subscriptionPlan = "Claude Pro"
        XCTAssertEqual(ProfileRowPresentation.planSubtitle(p, privacyMasked: true), "•••• Plan")
    }

    func testPlanSubtitleNilWhenNoPlan() {
        let p = Profile(name: "Test", authMethod: .cliSync)
        XCTAssertNil(ProfileRowPresentation.planSubtitle(p, privacyMasked: false))
        XCTAssertNil(ProfileRowPresentation.planSubtitle(p, privacyMasked: true))
    }

    // MARK: - isLive

    func testIsLiveClaudeMatchesByEmailCaseInsensitive() {
        let p = Profile(name: "C", authMethod: .cliSync, providerID: .claude, email: "User@Example.com")
        let live = ProfileLivenessContext(claudeCLIEmail: "user@example.com",
                                          codexCLIEmail: nil,
                                          antigravityProcessAlive: false)
        XCTAssertTrue(ProfileRowPresentation.isLive(p, liveness: live))

        let offline = ProfileLivenessContext(claudeCLIEmail: "other@example.com",
                                             codexCLIEmail: nil,
                                             antigravityProcessAlive: false)
        XCTAssertFalse(ProfileRowPresentation.isLive(p, liveness: offline))
    }

    func testIsLiveCodexMatchesByEmail() {
        let p = Profile(name: "X", authMethod: .cliSync, providerID: .codex, email: "a@b.com")
        let live = ProfileLivenessContext(claudeCLIEmail: nil,
                                          codexCLIEmail: "a@b.com",
                                          antigravityProcessAlive: false)
        XCTAssertTrue(ProfileRowPresentation.isLive(p, liveness: live))
    }

    func testIsLiveAntigravityUsesProcessFlagNotEmail() {
        let p = Profile(name: "A", authMethod: .cliSync, providerID: .antigravity, email: "a@b.com")
        let alive = ProfileLivenessContext(claudeCLIEmail: nil,
                                           codexCLIEmail: nil,
                                           antigravityProcessAlive: true)
        XCTAssertTrue(ProfileRowPresentation.isLive(p, liveness: alive))

        let dead = ProfileLivenessContext(claudeCLIEmail: nil,
                                          codexCLIEmail: nil,
                                          antigravityProcessAlive: false)
        XCTAssertFalse(ProfileRowPresentation.isLive(p, liveness: dead))
    }

    // MARK: - badges

    func testBadgesIncludeProviderPillByDefault() {
        let p = Profile(name: "C", authMethod: .cliSync, providerID: .claude)
        let badges = ProfileRowPresentation.badges(
            for: p, providerName: "Claude", isLive: true
        )
        XCTAssertEqual(badges.count, 1)
        XCTAssertEqual(badges.first?.text, "Claude")
    }

    func testBadgesAppendOfflinePillWhenNotLive() {
        let p = Profile(name: "C", authMethod: .cliSync, providerID: .codex)
        let badges = ProfileRowPresentation.badges(
            for: p, providerName: "Codex", isLive: false
        )
        XCTAssertEqual(badges.map(\.text), ["Codex", "Offline"])
    }

    func testBadgesOmitOfflinePillWhenSuppressed() {
        let p = Profile(name: "C", authMethod: .cliSync, providerID: .codex)
        let badges = ProfileRowPresentation.badges(
            for: p, providerName: "Codex", isLive: false, includeOfflinePill: false
        )
        XCTAssertEqual(badges.map(\.text), ["Codex"])
    }

    // MARK: - ordered

    func testOrderedExcludesArchivedProfiles() {
        var archived = Profile(name: "Archived", authMethod: .cliSync,
                               providerID: .antigravity)
        archived.kind = .archived
        let auto = Profile(name: "AutoLive", authMethod: .cliSync,
                           providerID: .antigravity)
        let live = ProfileLivenessContext(claudeCLIEmail: nil,
                                          codexCLIEmail: nil,
                                          antigravityProcessAlive: true)
        let out = ProfileRowPresentation.ordered([archived, auto], liveness: live)
        XCTAssertEqual(out.map(\.name), ["AutoLive"])
    }

    func testOrderedPlacesLiveBeforeOfflineAndPreservesWithinGroup() {
        let claudeLive = Profile(name: "ClaudeLive", authMethod: .cliSync,
                                 providerID: .claude, email: "live@x.com")
        let claudeOffline = Profile(name: "ClaudeOff", authMethod: .cliSync,
                                    providerID: .claude, email: "off@x.com")
        let codexLive = Profile(name: "CodexLive", authMethod: .cliSync,
                                providerID: .codex, email: "c@x.com")
        let agOffline = Profile(name: "AGOff", authMethod: .cliSync,
                                providerID: .antigravity)

        // Input order intentionally interleaves live + offline so the test
        // catches a broken sort that only looks at the first element.
        let input = [claudeOffline, claudeLive, agOffline, codexLive]
        let live = ProfileLivenessContext(claudeCLIEmail: "live@x.com",
                                          codexCLIEmail: "c@x.com",
                                          antigravityProcessAlive: false)

        let out = ProfileRowPresentation.ordered(input, liveness: live)
        XCTAssertEqual(out.map(\.name), ["ClaudeLive", "CodexLive", "ClaudeOff", "AGOff"])
    }
}
