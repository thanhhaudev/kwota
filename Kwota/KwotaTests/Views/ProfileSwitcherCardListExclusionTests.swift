//
//  ProfileSwitcherCardListExclusionTests.swift
//  KwotaTests
//
//  Locks the rule that the inline list card excludes the active
//  profile (since the header card above it already carries that info)
//  while canExpand still derives from total live count. Pure-data
//  tests against the static helper, mirroring ProfileSwitcherCardTests.
//

import XCTest
import SwiftUI
@testable import Kwota

@MainActor
final class ProfileSwitcherCardListExclusionTests: XCTestCase {
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

    // MARK: - Exclusion

    func test_excludesActiveRow_twoProfiles() {
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
            FakeProvider(id: .codex,  displayName: "Codex",  iconAssetName: "terminal.fill"),
        ])
        let claude = claudeProfile("a@x.com")
        let codex  = codexProfile("b@x.com")
        let sections = ProfileSwitcherCard.switcherSections(
            profiles: [claude, codex],
            registry: registry,
            activeID: claude.id,
            now: Date()
        )
        let rows = ProfileSwitcherCard.orderedRowsExcludingActive(sections)
        XCTAssertEqual(rows.map(\.0.profileID), [codex.id])
    }

    func test_excludesActiveRow_threeProfiles_preservesSectionOrder() {
        // Forward-compat: even though live-only caps at 2 today, the
        // helper must not assume cap. Two providers, three profiles —
        // one Claude active, plus another Claude in the same section
        // and a Codex one. Active is dropped; remaining two come out
        // in section order (Claude before Codex per registry).
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
            FakeProvider(id: .codex,  displayName: "Codex",  iconAssetName: "terminal.fill"),
        ])
        let claude1 = claudeProfile("a@x.com")
        let claude2 = claudeProfile("b@x.com")
        let codex1  = codexProfile("c@x.com")
        let sections = ProfileSwitcherCard.switcherSections(
            profiles: [claude1, claude2, codex1],
            registry: registry,
            activeID: claude1.id,
            now: Date()
        )
        let rows = ProfileSwitcherCard.orderedRowsExcludingActive(sections)
        XCTAssertEqual(rows.map(\.0.profileID), [claude2.id, codex1.id])
    }

    func test_singleActiveProfile_listIsEmpty() {
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
        let rows = ProfileSwitcherCard.orderedRowsExcludingActive(sections)
        XCTAssertTrue(rows.isEmpty)
    }

    func test_noActive_keepsAllRows() {
        // Defensive: if activeID happens to be nil (transition state),
        // the helper returns every row instead of crashing or dropping
        // the wrong one.
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
        ])
        let p1 = claudeProfile("a@x.com")
        let p2 = claudeProfile("b@x.com")
        let sections = ProfileSwitcherCard.switcherSections(
            profiles: [p1, p2],
            registry: registry,
            activeID: nil,
            now: Date()
        )
        let rows = ProfileSwitcherCard.orderedRowsExcludingActive(sections)
        XCTAssertEqual(rows.map(\.0.profileID), [p1.id, p2.id])
    }

    // MARK: - canExpand rule (derived from total live count)

    func test_canExpandRule_totalLiveCountAtLeastTwo() {
        // canExpand is computed inside the view body, but the underlying
        // assumption — total live count ≥ 2 → expandable — is tested via
        // the section/row totals the helper returns. The view's
        // canExpand expression is `liveRowCount >= 2` over sections, so
        // we lock that invariant here.
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
            FakeProvider(id: .codex,  displayName: "Codex",  iconAssetName: "terminal.fill"),
        ])
        let claude = claudeProfile("a@x.com")
        let codex  = codexProfile("b@x.com")

        let sectionsTwo = ProfileSwitcherCard.switcherSections(
            profiles: [claude, codex],
            registry: registry,
            activeID: claude.id,
            now: Date()
        )
        let liveTwo = sectionsTwo.reduce(0) { $0 + $1.rows.count }
        XCTAssertGreaterThanOrEqual(liveTwo, 2, "two providers, one profile each → expandable")

        let sectionsOne = ProfileSwitcherCard.switcherSections(
            profiles: [claude],
            registry: registry,
            activeID: claude.id,
            now: Date()
        )
        let liveOne = sectionsOne.reduce(0) { $0 + $1.rows.count }
        XCTAssertLessThan(liveOne, 2, "only one live profile → not expandable")
    }

    // MARK: - Row label uses resolvedDisplayName

    func test_switcherRow_prefersDisplayName_overName() {
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
        ])
        var p = claudeProfile("a@x.com")   // name == "a@x.com", displayName nil
        p.displayName = "Renamed Hau"      // simulates a post-refresh API name
        let sections = ProfileSwitcherCard.switcherSections(
            profiles: [p], registry: registry, activeID: nil, now: Date())
        XCTAssertEqual(sections.first?.rows.first?.displayName, "Renamed Hau")
    }

    func test_switcherRow_fallsBackToName_whenNoDisplayName() {
        let registry = makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
        ])
        let p = claudeProfile("a@x.com")   // displayName nil → resolved == name
        let sections = ProfileSwitcherCard.switcherSections(
            profiles: [p], registry: registry, activeID: nil, now: Date())
        XCTAssertEqual(sections.first?.rows.first?.displayName, "a@x.com")
    }
}

// MARK: - Test doubles

@MainActor
private final class FakeProvider: AccountProvider {
    let id: ProviderID
    let displayName: String
    let iconAssetName: String
    let supportedAuthMethods: [any ProviderAuthMethod] = []
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
}
