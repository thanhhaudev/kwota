//
//  ManageProfilesAccountRowsTests.swift
//  KwotaTests
//
//  Pure-data tests for ManageProfilesView.accountRows — the helper that turns
//  ProviderRegistry order + profiles + active id + a liveness predicate into
//  the ordered "Accounts" section rows. The SwiftUI body is rebuilt from this,
//  so these tests cover the user-visible ordering and active/live marking.
//

import XCTest
import SwiftUI
@testable import Kwota

@MainActor
final class ManageProfilesAccountRowsTests: XCTestCase {
    private func makeRegistry(_ providers: [any AccountProvider]) -> ProviderRegistry {
        let r = ProviderRegistry()
        providers.forEach { r.register($0) }
        return r
    }

    private func profile(
        _ providerID: ProviderID,
        email: String,
        kind: ProfileKind = .auto,
        id: UUID = UUID()
    ) -> Profile {
        Profile(id: id, name: email, authMethod: .cliSync, providerID: providerID, email: email, kind: kind)
    }

    private func registry3() -> ProviderRegistry {
        makeRegistry([
            FakeProvider(id: .claude, displayName: "Claude", iconAssetName: "Mascot"),
            FakeProvider(id: .codex, displayName: "Codex", iconAssetName: "CodexLogo"),
            FakeProvider(id: .antigravity, displayName: "Antigravity", iconAssetName: "AntigravityLogo"),
        ])
    }

    func test_includesAllAutoProvidersInRegistryOrder() {
        let registry = registry3()
        let cl = profile(.claude, email: "a@x.com")
        let cx = profile(.codex, email: "c@x.com")
        let ag = profile(.antigravity, email: "g@x.com")
        let rows = ManageProfilesView.accountRows(
            profiles: [cx, ag, cl],
            registry: registry,
            activeID: nil,
            isLive: { _ in true }
        )
        XCTAssertEqual(rows.map { $0.profile.providerID }, [.claude, .codex, .antigravity])
        XCTAssertTrue(rows.allSatisfy { !$0.isActive })
        XCTAssertTrue(rows.allSatisfy { $0.isLive })
    }

    func test_excludesArchived() {
        let registry = registry3()
        let cl = profile(.claude, email: "a@x.com")
        let cxArchived = profile(.codex, email: "c@x.com", kind: .archived)
        let rows = ManageProfilesView.accountRows(
            profiles: [cl, cxArchived],
            registry: registry,
            activeID: nil,
            isLive: { _ in true }
        )
        XCTAssertEqual(rows.map { $0.profile.providerID }, [.claude])
    }

    func test_activeFloatsToTopAndIsFlagged() {
        let registry = registry3()
        let cl = profile(.claude, email: "a@x.com")
        let cx = profile(.codex, email: "c@x.com")
        let rows = ManageProfilesView.accountRows(
            profiles: [cl, cx],
            registry: registry,
            activeID: cx.id,
            isLive: { _ in true }
        )
        XCTAssertEqual(rows.first?.profile.id, cx.id)
        XCTAssertEqual(rows.first?.isActive, true)
        XCTAssertEqual(rows.last?.profile.id, cl.id)
        XCTAssertEqual(rows.last?.isActive, false)
    }

    func test_marksNonLive() {
        let registry = registry3()
        let cl = profile(.claude, email: "a@x.com")
        let cx = profile(.codex, email: "c@x.com")
        let rows = ManageProfilesView.accountRows(
            profiles: [cl, cx],
            registry: registry,
            activeID: nil,
            isLive: { $0.id == cl.id }
        )
        let claudeRow = rows.first { $0.profile.id == cl.id }
        let codexRow = rows.first { $0.profile.id == cx.id }
        XCTAssertEqual(claudeRow?.isLive, true)
        XCTAssertEqual(codexRow?.isLive, false)
    }
}

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
