//
//  MenuBarViewModelChartStateTests.swift
//  KwotaTests
//
//  Covers MenuBarViewModel.resolveUsageChartState(...) — the pure static
//  helper that resolves the Usage tab's chart region between loading /
//  provider view / empty. The regression fence is the Codex-active +
//  no-summary case, which previously rendered EmptyView because UsageTabView
//  substituted a Claude payload into the fallback ProviderUsageSummary.
//

import XCTest
@testable import Kwota

@MainActor
final class MenuBarViewModelChartStateTests: XCTestCase {
    private func claudeProfile() -> Profile {
        Profile(name: "Claude", authMethod: .cliSync, providerID: .claude, email: "c@x.com")
    }

    private func codexProfile() -> Profile {
        Profile(name: "Codex", authMethod: .cliSync, providerID: .codex, email: "z@x.com")
    }

    private func resolve(
        profile: Profile,
        summary: ProviderUsageSummary? = nil,
        snapshot: UsageSnapshot? = nil,
        isSwitchingProfile: Bool = false
    ) -> MenuBarViewModel.UsageChartState {
        MenuBarViewModel.resolveUsageChartState(
            for: profile,
            summary: summary,
            snapshot: snapshot,
            isSwitchingProfile: isSwitchingProfile
        )
    }

    // MARK: - Codex paths (regression fence)

    func test_codexActive_noSummary_noSnapshot_isEmpty() {
        let state = resolve(profile: codexProfile())
        guard case .empty = state else { return XCTFail("expected .empty, got \(state)") }
    }

    func test_codexActive_withSummary_isProviderView() {
        let summary = ProviderUsageSummary(
            providerID: .codex,
            fetchedAt: Date(),
            primary: nil,
            secondary: nil,
            payload: CodexUsageSnapshot()
        )
        let state = resolve(profile: codexProfile(), summary: summary)
        guard case .providerView(let s) = state else { return XCTFail("expected .providerView") }
        XCTAssertEqual(s.providerID, .codex)
    }

    // MARK: - Claude paths

    func test_claudeActive_noSummary_noSnapshot_isEmpty() {
        let state = resolve(profile: claudeProfile())
        guard case .empty = state else { return XCTFail("expected .empty") }
    }

    func test_claudeActive_noSummary_cachedSnapshot_isProviderViewWithCachedPayload() {
        let cached = UsageSnapshot.zeroes()
        let state = resolve(profile: claudeProfile(), snapshot: cached)
        guard case .providerView(let s) = state else { return XCTFail("expected .providerView") }
        XCTAssertEqual(s.providerID, .claude)
        XCTAssertNotNil(s.payload as? UsageSnapshot, "payload must be UsageSnapshot for Claude cached path")
    }

    func test_claudeActive_withSummary_prefersSummaryOverSnapshot() {
        let cached = UsageSnapshot.zeroes()
        let liveSummary = ProviderUsageSummary(
            providerID: .claude,
            fetchedAt: Date(),
            primary: nil,
            secondary: nil,
            payload: cached
        )
        let state = resolve(profile: claudeProfile(), summary: liveSummary, snapshot: cached)
        guard case .providerView(let s) = state else { return XCTFail("expected .providerView") }
        XCTAssertEqual(s.fetchedAt, liveSummary.fetchedAt)
    }

    // MARK: - Loading path

    func test_anyProvider_isSwitchingWithNoData_isLoading() {
        guard case .loading = resolve(profile: claudeProfile(), isSwitchingProfile: true) else {
            return XCTFail("expected .loading for Claude")
        }
        guard case .loading = resolve(profile: codexProfile(), isSwitchingProfile: true) else {
            return XCTFail("expected .loading for Codex")
        }
    }

    func test_isSwitchingButHasSnapshot_prefersProviderViewOverLoading() {
        // A cached Claude snapshot during switch still renders provider view —
        // matches the existing offline-first behaviour the spec preserves.
        let state = resolve(
            profile: claudeProfile(),
            snapshot: UsageSnapshot.zeroes(),
            isSwitchingProfile: true
        )
        guard case .providerView = state else {
            return XCTFail("expected .providerView (Claude cached) over .loading")
        }
    }

    // MARK: - Provider-id guard (stale-summary fence)

    func test_codexActive_claudeSummaryFromPriorProfile_isIgnored() {
        // A leftover Claude summary must NOT render under a Codex profile,
        // even if it's the only thing in `summary`. ProviderUsageSummary has
        // no profile id, so providerID equality is the minimum guard.
        let claudeLeftover = ProviderUsageSummary(
            providerID: .claude,
            fetchedAt: Date(),
            primary: nil,
            secondary: nil,
            payload: UsageSnapshot.zeroes()
        )
        let state = resolve(profile: codexProfile(), summary: claudeLeftover)
        guard case .empty = state else {
            return XCTFail("expected .empty (Claude summary on Codex profile rejected), got \(state)")
        }
    }

    func test_claudeActive_codexSummaryFromPriorProfile_isIgnored() {
        let codexLeftover = ProviderUsageSummary(
            providerID: .codex,
            fetchedAt: Date(),
            primary: nil,
            secondary: nil,
            payload: CodexUsageSnapshot()
        )
        // No Claude cached snapshot → falls through to .empty, NOT
        // .providerView(codexLeftover).
        let state = resolve(profile: claudeProfile(), summary: codexLeftover)
        guard case .empty = state else {
            return XCTFail("expected .empty (Codex summary on Claude profile rejected), got \(state)")
        }
    }

    func test_claudeActive_codexSummaryButCachedClaudeSnapshot_usesCachedSnapshot() {
        // Mismatched summary should NOT block the offline-first Claude path.
        // A cached Claude snapshot is still valid for the Claude profile —
        // the guard rejects only the wrong-provider summary, not the cache.
        let codexLeftover = ProviderUsageSummary(
            providerID: .codex,
            fetchedAt: Date(),
            primary: nil,
            secondary: nil,
            payload: CodexUsageSnapshot()
        )
        let cached = UsageSnapshot.zeroes()
        let state = resolve(profile: claudeProfile(), summary: codexLeftover, snapshot: cached)
        guard case .providerView(let s) = state else {
            return XCTFail("expected .providerView (Claude cached fallback), got \(state)")
        }
        XCTAssertEqual(s.providerID, .claude)
    }
}
