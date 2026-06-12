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
                    // 1s clock so the banner *selection* re-evaluates as
                    // the rate-limit window / staleness threshold elapses.
                    // The countdown text already ticked (RateLimitBanner
                    // owns a TimelineView), but the branch choice here
                    // used a render-time Date() — an expired banner
                    // lingered on "Back-off elapsed" until some unrelated
                    // VM change forced a redraw, and the StaleDataBanner
                    // behind it stayed suppressed.
                    //
                    // spacing-0 wrapper: the TimelineView is a permanent
                    // stack child, so in the outer spacing-10 VStack its
                    // zero-size no-banner state still earned a spacing
                    // slot — a phantom 10pt above the profile card that
                    // no other tab had. Each banner branch carries its
                    // own .padding(.bottom, 10) instead; padding must sit
                    // INSIDE the branches because a modifier on the
                    // resolved-empty builder output materializes the same
                    // phantom gap (measured in ZeroSizeChildSpacingTests).
                    VStack(alignment: .leading, spacing: 0) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            statusBanner(now: context.date)
                        }

                        ProfileSwitcherCard(vm: vm)
                    }

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
                                vm.refreshUsageNow(trigger: .manual)
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            // Manual tier: gated by the capped rate-limit
                            // window (≤5 min), not the verbatim server
                            // floor — the user regains the button in
                            // minutes even when Anthropic asks for 2400s.
                            .disabled(
                                vm.authState == .refreshing
                                || !vm.canRefreshNow(now: context.date, trigger: .manual)
                            )
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func statusBanner(now: Date) -> some View {
        switch vm.authState {
        case .error, .unauthenticated, .expired:
            let provider = vm.profileStore.activeProfile
                .flatMap { vm.registry.provider(for: $0.providerID) }
            ReAuthBanner(
                title: provider?.reauthTitle ?? "CLI session expired",
                detail: provider?.reauthInstruction
                    ?? "Authorization expired. Sign in again."
            )
            .padding(.bottom, 10)
        case .authenticated:
            if let until = vm.rateLimitedUntil, until > now {
                // "Try now" is the probe tier: it bypasses the back-off
                // floor entirely (that's its purpose — the floor is the
                // reason this banner exists). Only the burst throttle
                // applies.
                // probeEnabled tracks the real gate: this whole banner
                // sits under a 1s TimelineView, so the button greys for
                // the ~10s burst-throttle window right after the 429
                // (when a click would be silently swallowed) and lights
                // up the moment a probe can actually fire.
                RateLimitBanner(
                    retryAt: until,
                    probeEnabled: vm.canRefreshNow(now: now, trigger: .probe),
                    onRetry: { vm.refreshUsageNow(trigger: .probe) }
                )
                .padding(.bottom, 10)
            } else if let last = vm.lastFetchedAt,
                      now.timeIntervalSince(last) > StaleDataBanner.threshold {
                StaleDataBanner(lastFetchedAt: last, onRefresh: { vm.refreshUsageNow(trigger: .manual) })
                    .padding(.bottom, 10)
            }
        case .refreshing:
            // Keep the rate-limit banner mounted (with a spinner in the
            // action slot) while a probe is in flight. Dropping it here
            // made "Try now" look like the banner blinked away and came
            // back — or, before the probe tier existed, like nothing
            // happened at all.
            if let until = vm.rateLimitedUntil, until > now {
                RateLimitBanner(retryAt: until, isProbing: true, onRetry: {})
                    .padding(.bottom, 10)
            } else {
                EmptyView()
            }
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
