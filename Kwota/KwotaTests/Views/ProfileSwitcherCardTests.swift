//
//  ProfileSwitcherCardTests.swift
//  KwotaTests
//
//  Pure-data tests for ProfileSwitcherCard.switcherSections — the
//  grouping helper that turns ProviderRegistry + profiles + active id into
//  the menu's section/row plan. View body is rebuilt from this, so tests
//  here cover the user-visible ordering and active-marking guarantees.
//

import XCTest
import SwiftUI
@testable import Kwota

@MainActor
final class ProfileSwitcherCardTests: XCTestCase {
    private func makeRegistry(_ providers: [any AccountProvider]) -> ProviderRegistry {
        let r = ProviderRegistry()
        providers.forEach { r.register($0) }
        return r
    }

    private func claudeProfile(_ email: String, id: UUID = UUID()) -> Profile {
        Profile(
            id: id,
            name: email,
            authMethod: .cliSync,
            providerID: .claude,
            email: email
        )
    }

    private func codexProfile(_ email: String, id: UUID = UUID()) -> Profile {
        Profile(
            id: id,
            name: email,
            authMethod: .cliSync,
            providerID: .codex,
            email: email
        )
    }

    // MARK: - Grouping

    func test_groupsByProviderInRegistryOrder() {
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
            FakeProvider(id: .codex,  displayName: "Codex",  iconAssetName: "terminal.fill"),
        ])
        let claude1 = claudeProfile("a@x.com")
        let codex1  = codexProfile("c@x.com")
        let sections = ProfileSwitcherCard.switcherSections(
            profiles: [codex1, claude1],   // not in registry order on purpose
            registry: registry,
            activeID: claude1.id,
            now: Date()
        )
        XCTAssertEqual(sections.map(\.providerID), [.claude, .codex])
        XCTAssertEqual(sections[0].rows.map(\.profileID), [claude1.id])
        XCTAssertEqual(sections[1].rows.map(\.profileID), [codex1.id])
    }

    func test_marksActiveRowOnly() {
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
        ])
        let p1 = claudeProfile("a@x.com")
        let p2 = claudeProfile("b@x.com")
        let sections = ProfileSwitcherCard.switcherSections(
            profiles: [p1, p2],
            registry: registry,
            activeID: p2.id,
            now: Date()
        )
        XCTAssertEqual(sections.count, 1)
        let actives = sections[0].rows.map(\.isActive)
        XCTAssertEqual(actives, [false, true])
    }

    func test_dropsProvidersWithNoProfiles() {
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
            FakeProvider(id: .codex,  displayName: "Codex",  iconAssetName: "terminal.fill"),
        ])
        let p1 = claudeProfile("a@x.com")
        let sections = ProfileSwitcherCard.switcherSections(
            profiles: [p1],
            registry: registry,
            activeID: p1.id,
            now: Date()
        )
        XCTAssertEqual(sections.map(\.providerID), [.claude])
    }

    func test_filtersOutNonLiveProfiles() {
        // isLive predicate keeps only the live CLI per provider. Caller
        // builds the predicate from CLIAccountWatcher / CodexAccountWatcher
        // emails; here we stub it with a Set lookup.
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
            FakeProvider(id: .codex,  displayName: "Codex",  iconAssetName: "CodexLogo"),
        ])
        let claudeLive = claudeProfile("live@x.com")
        let claudeStale = claudeProfile("stale@x.com")
        let codexLive = codexProfile("codex@x.com")
        let liveIDs: Set<UUID> = [claudeLive.id, codexLive.id]
        let sections = ProfileSwitcherCard.switcherSections(
            profiles: [claudeStale, claudeLive, codexLive],
            registry: registry,
            activeID: claudeLive.id,
            now: Date(),
            isLive: { liveIDs.contains($0.id) }
        )
        XCTAssertEqual(sections.flatMap(\.rows).map(\.profileID), [claudeLive.id, codexLive.id])
    }

    func test_archivedProfile_neverShowsInPicker_evenWhenLive() {
        // Archived profiles are retired accounts; the picker must hide them
        // even if their email coincidentally matches a current CLI identity.
        // ProfileStore.setActive doesn't gate by kind, so the picker is the
        // last fence preventing a user from reactivating an archived row.
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
        ])
        let live = claudeProfile("user@x.com")
        let archived = Profile(
            id: UUID(),
            name: "user@x.com",
            authMethod: .cliSync,
            providerID: .claude,
            email: "user@x.com",
            kind: .archived
        )
        let sections = ProfileSwitcherCard.switcherSections(
            profiles: [archived, live],
            registry: registry,
            activeID: live.id,
            now: Date(),
            isLive: { _ in true }
        )
        XCTAssertEqual(sections.flatMap(\.rows).map(\.profileID), [live.id])
    }

    // MARK: - isLive static helper

    func test_isLive_matchesEmailCaseInsensitively() {
        // Identity matching everywhere else in the codebase
        // (ProfileStore.findMatching, AutoProfileCoordinator,
        // AutoProfileMigrator) uses caseInsensitiveCompare. The picker's
        // isLive must follow suit so a stored "user@example.com" stays
        // visible when the CLI surfaces "User@Example.com".
        let stored = claudeProfile("user@example.com")
        XCTAssertTrue(ProfileSwitcherCard.isLive(
            profile: stored,
            claudeCLIEmail: "User@Example.com",
            codexCLIEmail: nil
        ))
    }

    func test_isLive_returnsFalseWhenWatcherHasDifferentEmail() {
        let stored = claudeProfile("a@x.com")
        XCTAssertFalse(ProfileSwitcherCard.isLive(
            profile: stored,
            claudeCLIEmail: "b@x.com",
            codexCLIEmail: nil
        ))
    }

    func test_isLive_antigravity_followsProcessAliveFlag() {
        // Antigravity liveness is "the language_server process is running"
        // — not email match (Antigravity profiles often start with nil
        // email and only back-fill after the first successful fetch).
        let agy = Profile(
            id: UUID(),
            name: "Antigravity",
            authMethod: .cliSync,
            providerID: .antigravity,
            email: nil
        )
        XCTAssertTrue(ProfileSwitcherCard.isLive(
            profile: agy,
            claudeCLIEmail: nil,
            codexCLIEmail: nil,
            antigravityProcessAlive: true
        ))
        XCTAssertFalse(ProfileSwitcherCard.isLive(
            profile: agy,
            claudeCLIEmail: nil,
            codexCLIEmail: nil,
            antigravityProcessAlive: false
        ))
    }

    // MARK: - barIcons

    func test_barIcons_antigravity_usesCubeAndCreditcard() {
        // Antigravity's primary = worst-model utilization → `cube`.
        // Secondary = AI Credits utilization → `creditcard`. The
        // tooltip on the row hover still carries the full semantic.
        let icons = ProfileSwitcherCard.barIcons(for: .antigravity)
        XCTAssertEqual(icons.0, "cube")
        XCTAssertEqual(icons.1, "creditcard")
    }

    func test_barIcons_claudeAndCodex_useClockAndCalendar() {
        // Claude and Codex both report 5-hour primary + weekly secondary
        // rate-limit windows. Time-based glyphs read at a glance.
        XCTAssertEqual(ProfileSwitcherCard.barIcons(for: .claude).0, "clock")
        XCTAssertEqual(ProfileSwitcherCard.barIcons(for: .claude).1, "calendar")
        XCTAssertEqual(ProfileSwitcherCard.barIcons(for: .codex).0, "clock")
        XCTAssertEqual(ProfileSwitcherCard.barIcons(for: .codex).1, "calendar")
    }

    func test_inactiveRowSummary_returnsSummaryForLoadedAndStale() {
        // Both .loaded and .stale carry a usable payload, so the bar and the
        // reset subtitle (which both resolve through this) describe the same
        // fetch. A stale row must NOT yield nil, or its subtitle would fall
        // back to an unrelated reset source while the bar shows real data.
        let summary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: Date(),
            primary: nil, secondary: nil, payload: 0 as Int)
        XCTAssertNotNil(ProfileSwitcherCard.inactiveRowSummary(.loaded(summary)))
        XCTAssertNotNil(ProfileSwitcherCard.inactiveRowSummary(.stale(summary)),
                        "stale must surface its summary so bar and subtitle stay coherent")
        XCTAssertEqual(
            ProfileSwitcherCard.inactiveRowSummary(.stale(summary))?.fetchedAt,
            summary.fetchedAt)
    }

    func test_inactiveRowSummary_nilForIdleLoadingError() {
        XCTAssertNil(ProfileSwitcherCard.inactiveRowSummary(.idle))
        XCTAssertNil(ProfileSwitcherCard.inactiveRowSummary(.loading))
        XCTAssertNil(ProfileSwitcherCard.inactiveRowSummary(.error("boom")))
    }

    func test_filterEmptyingAProvider_dropsTheSection() {
        // When every Claude profile is non-live, the whole CLAUDE section
        // disappears — empty-section drop still wins over predicate output.
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
            FakeProvider(id: .codex,  displayName: "Codex",  iconAssetName: "CodexLogo"),
        ])
        let claudeStale = claudeProfile("stale@x.com")
        let codexLive = codexProfile("codex@x.com")
        let sections = ProfileSwitcherCard.switcherSections(
            profiles: [claudeStale, codexLive],
            registry: registry,
            activeID: codexLive.id,
            now: Date(),
            isLive: { $0.id == codexLive.id }
        )
        XCTAssertEqual(sections.map(\.providerID), [.codex])
    }

    func test_preservesInputProfileOrderWithinSection() {
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
        ])
        let p1 = claudeProfile("a@x.com")
        let p2 = claudeProfile("b@x.com")
        let p3 = claudeProfile("c@x.com")
        let sections = ProfileSwitcherCard.switcherSections(
            profiles: [p2, p3, p1],
            registry: registry,
            activeID: p3.id,
            now: Date()
        )
        XCTAssertEqual(sections[0].rows.map(\.profileID), [p2.id, p3.id, p1.id])
    }

    func test_singleLiveProfile_yieldsOneRow_soNoChevron() {
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
        ])
        let only = claudeProfile("a@x.com")
        let sections = ProfileSwitcherCard.switcherSections(
            profiles: [only],
            registry: registry,
            activeID: only.id,
            now: Date()
        )
        let liveRowCount = sections.reduce(0) { $0 + $1.rows.count }
        XCTAssertEqual(liveRowCount, 1,
                       "a single live profile keeps liveRowCount at 1 → canExpand is false → no chevron")
    }

    // MARK: - Subtitle formatter

    func test_makeSubtitle_planAndRenewal_joinsWithDot() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let expectedDate = MenuBarViewModel.formattedRenewalDate(date)
        let subtitle = ProfileSwitcherCard.makeSubtitle(
            plan: "Plus",
            datePart: "Est. \(expectedDate)",
            email: "u@x.com",
            displayName: "Hau"
        )
        XCTAssertEqual(subtitle, "Plus · Est. \(expectedDate)")
    }

    func test_makeSubtitle_planOnly_returnsPlanVerbatim() {
        let subtitle = ProfileSwitcherCard.makeSubtitle(
            plan: "Pro",
            datePart: nil,
            email: "u@x.com",
            displayName: "Hau"
        )
        XCTAssertEqual(subtitle, "Pro")
    }

    func test_makeSubtitle_renewalOnly_prefixesEst() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let expectedDate = MenuBarViewModel.formattedRenewalDate(date)
        let subtitle = ProfileSwitcherCard.makeSubtitle(
            plan: nil,
            datePart: "Est. \(expectedDate)",
            email: "u@x.com",
            displayName: "Hau"
        )
        XCTAssertEqual(subtitle, "Est. \(expectedDate)")
    }

    func test_makeSubtitle_bothNil_fallsBackToEmailWhenDistinctFromName() {
        let subtitle = ProfileSwitcherCard.makeSubtitle(
            plan: nil,
            datePart: nil,
            email: "u@x.com",
            displayName: "Hau"
        )
        XCTAssertEqual(subtitle, "u@x.com")
    }

    func test_makeSubtitle_bothNil_emptyWhenEmailEqualsDisplayName() {
        // Codex auto profiles often persist `name == email`; in that case
        // showing the email again under the name is duplicate noise.
        let subtitle = ProfileSwitcherCard.makeSubtitle(
            plan: nil,
            datePart: nil,
            email: "u@x.com",
            displayName: "u@x.com"
        )
        XCTAssertEqual(subtitle, "")
    }

    func test_makeSubtitle_bothNil_emptyWhenEmailIsEmpty() {
        let subtitle = ProfileSwitcherCard.makeSubtitle(
            plan: nil,
            datePart: nil,
            email: "",
            displayName: "Hau"
        )
        XCTAssertEqual(subtitle, "")
    }

    // MARK: - End-to-end: subtitle propagated to Row

    func test_switcherSections_populatesSubtitleFromProfileFields() {
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
        ])
        let renewsAt = Date(timeIntervalSince1970: 1_800_000_000)
        let p = Profile(
            id: UUID(),
            name: "Hau",
            authMethod: .cliSync,
            providerID: .claude,
            subscriptionPlan: "Plus",
            subscriptionRenewsAt: renewsAt,
            email: "hau@x.com"
        )
        let sections = ProfileSwitcherCard.switcherSections(
            profiles: [p],
            registry: registry,
            activeID: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].rows.count, 1)
        let expectedDate = MenuBarViewModel.formattedRenewalDate(renewsAt)
        XCTAssertEqual(sections[0].rows[0].subtitle, "Plus · Est. \(expectedDate)")
    }

    func test_switcherSections_forwardsSummaryForFallbackEstimate() {
        // Provider renders a fallback estimate ONLY when handed a summary —
        // mirrors Antigravity's model-reset fallback. Proves switcherSections
        // forwards its `summaryFor` lookup into renewalEstimate(summary:).
        let provider = FakeProvider(id: .antigravity, displayName: "Antigravity", iconAssetName: "Mascot")
        let resetDate = Date(timeIntervalSince1970: 1_700_007_200)
        provider.renewalEstimateOverride = { _, summary, _ in
            guard summary != nil else { return nil }   // nothing without a live summary
            return RenewalEstimate(date: resetDate, prefix: "Resets", absolute: false)
        }
        let registry = makeRegistry([provider])
        let p = Profile(id: UUID(), name: "Hau", authMethod: .cliSync,
                        providerID: .antigravity, subscriptionPlan: "AI Pro")
        let liveSummary = ProviderUsageSummary(
            providerID: .antigravity, fetchedAt: Date(),
            primary: nil, secondary: nil, payload: 0 as Int)

        // Without a summary lookup → no date part, plan only.
        let withoutSummary = ProfileSwitcherCard.switcherSections(
            profiles: [p], registry: registry, activeID: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(withoutSummary[0].rows[0].subtitle, "AI Pro")

        // With a summary lookup → fallback estimate renders.
        let withSummary = ProfileSwitcherCard.switcherSections(
            profiles: [p], registry: registry, activeID: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            summaryFor: { _ in liveSummary })
        XCTAssertTrue(withSummary[0].rows[0].subtitle.hasPrefix("AI Pro · Resets "),
                      withSummary[0].rows[0].subtitle)
    }

}

// MARK: - Test doubles

@MainActor
private final class FakeProvider: AccountProvider {
    let id: ProviderID
    let displayName: String
    let iconAssetName: String
    let supportedAuthMethods: [any ProviderAuthMethod] = []
    /// Optional override so a test can drive `renewalEstimate` from the
    /// passed-in `summary` (e.g. to verify `switcherSections` forwards its
    /// `summaryFor` lookup). nil = use the protocol default.
    var renewalEstimateOverride: ((Profile, ProviderUsageSummary?, Date) -> RenewalEstimate?)?
    init(id: ProviderID, displayName: String, iconAssetName: String) {
        self.id = id
        self.displayName = displayName
        self.iconAssetName = iconAssetName
    }
    func fetchUsage(credential: Credential, profile: Profile) async throws -> ProviderUsageSummary {
        ProviderUsageSummary(providerID: id, fetchedAt: Date(), primary: nil, secondary: nil, payload: UsageSnapshot.zeroes())
    }
    func usageDetailView(summary: ProviderUsageSummary, history: [UsageHistoryEntry], profile: Profile) -> AnyView {
        AnyView(EmptyView())
    }
    func planBadgeView(profile: Profile) -> AnyView { AnyView(EmptyView()) }
    func renewalEstimate(profile: Profile, summary: ProviderUsageSummary?, now: Date) -> RenewalEstimate? {
        if let renewalEstimateOverride { return renewalEstimateOverride(profile, summary, now) }
        // No override: mirror the protocol's default subscription estimate so
        // existing tests (which rely on the default) keep their behavior.
        guard let date = RenewalEstimator.subscription(for: profile, now: now) else { return nil }
        return RenewalEstimate(date: date, prefix: "Est.", absolute: true)
    }
}
