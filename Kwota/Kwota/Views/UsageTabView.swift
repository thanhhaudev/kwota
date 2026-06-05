//
//  UsageTabView.swift
//  Kwota
//

import SwiftUI

struct UsageTabView: View {
    let vm: MenuBarViewModel

    var body: some View {
        usageContent
    }

    private var usageContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if vm.hasNoActiveProfile {
                    NoActiveAccountEmptyView(
                        providerNames: vm.registry.all.map(\.displayName))
                } else if vm.showLoadingPlaceholder {
                    ProgressView("Refreshing…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if let profile = vm.profileStore.activeProfile {
                    statusBanner

                    ProfileSwitcherCard(vm: vm)

                    // Resolve the chart region via the VM's pure helper so the
                    // view never substitutes a provider-mismatched payload. The
                    // Codex render bug — UsageSnapshot.zeroes() injected into a
                    // ProviderUsageSummary with providerID = .codex — lived here.
                    switch vm.usageChartState(for: profile) {
                    case .loading:
                        ProgressView("Refreshing…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    case .providerView(let summary):
                        if let provider = vm.registry.provider(for: profile.providerID) {
                            provider.usageDetailView(
                                summary: summary,
                                history: vm.history,
                                profile: profile
                            )
                        } else {
                            EmptyChartPlaceholder()
                        }
                    case .empty:
                        EmptyChartPlaceholder()
                    }

                    // 1s TimelineView so the disabled state of the Refresh
                    // button re-evaluates as the throttle floor / back-off
                    // window elapses. `canRefreshNow(now:)` is a pure read
                    // against VM state + the supplied date, so the only
                    // thing missing for SwiftUI to flip the button on its
                    // own was a clock tick.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack {
                            updatedLabel
                            Spacer()
                            Button {
                                vm.refreshUsageNow()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .disabled(
                                vm.authState == .refreshing
                                || !vm.canRefreshNow(now: context.date)
                            )
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch vm.authState {
        case .error, .unauthenticated, .expired:
            let provider = vm.profileStore.activeProfile
                .flatMap { vm.registry.provider(for: $0.providerID) }
            ReAuthBanner(
                title: provider?.reauthTitle ?? "CLI session expired",
                detail: provider?.reauthInstruction
                    ?? "Authorization expired. Sign in again."
            )
        case .authenticated:
            if let until = vm.rateLimitedUntil, until > Date() {
                RateLimitBanner(retryAt: until, onRetry: { vm.refreshUsageNow() })
            } else if let last = vm.lastFetchedAt,
                      Date().timeIntervalSince(last) > StaleDataBanner.threshold {
                StaleDataBanner(lastFetchedAt: last, onRefresh: { vm.refreshUsageNow() })
            }
        case .refreshing:
            EmptyView()
        }
    }

    @ViewBuilder
    private var updatedLabel: some View {
        if vm.authState == .refreshing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Refreshing…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if let at = vm.lastFetchedAt {
            LiveUpdatedLabel(date: at)
        } else {
            Text("Not fetched yet")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Live-ticking "Updated X seconds ago" label. Extracted into its own View
/// (rather than inlined as a `@ViewBuilder` that wraps `TimelineView` in an
/// `if let`) so the `date` input flows in via the initializer. When the
/// parent VM publishes a newer `lastFetchedAt`, SwiftUI sees the input
/// change and rebuilds the body — guaranteeing the timestamp visibly resets
/// to "just now" right after a successful refresh, instead of relying on
/// closure capture invalidation that proved unreliable in popover redraws.
struct LiveUpdatedLabel: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("Updated \(RelativeTimeText.format(from: date, to: context.date))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Natural-language relative time used by the Usage tab footer. The system
/// `RelativeDateTimeFormatter` rounds "0 seconds" to a localized string that
/// reads oddly right after a refresh ("0 seconds ago"); this helper keeps
/// "just now" for the first few seconds and falls through to second/minute/
/// hour/day buckets after that. Fully spelled out (not abbreviated) so the
/// footer reads as a sentence.
enum RelativeTimeText {
    static func format(from: Date, to now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(from))
        if elapsed < 5 { return "just now" }
        if elapsed < 60 {
            let s = Int(elapsed)
            return "\(s) second\(s == 1 ? "" : "s") ago"
        }
        if elapsed < 3600 {
            let m = Int(elapsed / 60)
            return "\(m) minute\(m == 1 ? "" : "s") ago"
        }
        if elapsed < 86400 {
            let h = Int(elapsed / 3600)
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = Int(elapsed / 86400)
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }
}
