//
//  ProfileSwitcherCard.swift
//  Kwota
//
//  Inline-expanding profile switcher card. Renders ProfileCardView in its
//  collapsed slot; when the user has ≥2 CLI-live auto profiles, taps expand
//  the card downward inside the same `kwotaCard()` and reveal a per-profile
//  row with two utilization bars (5h primary + weekly secondary).
//
//  Tap on a non-active row → ProfileStore.setActive(id:) and collapse.
//  Single-live-profile case falls through to the plain ProfileCardView with
//  no chevron and no expand wiring (identical to today).
//
//  Per-row usage data is fetched lazily on expand through
//  `ProfileSwitcherFetchCoordinator`; the active row reuses `vm.summary`
//  to avoid a duplicate network call.
//
//  Also hosts EmptyChartPlaceholder, the "no data yet" placeholder shown
//  by UsageTabView when usageChartState resolves to .empty.
//

import SwiftUI
import AppKit
import Charts

struct EmptyChartPlaceholder: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No data yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Tap Refresh to load usage.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

struct ProfileSwitcherCard: View {
    let vm: MenuBarViewModel

    // MARK: Nested model

    struct Section: Equatable {
        let providerID: ProviderID
        let providerDisplayName: String
        let providerIconAssetName: String
        let rows: [Row]
    }

    struct Row: Equatable {
        let profileID: UUID
        let providerID: ProviderID
        let email: String
        let displayName: String
        /// Pre-formatted secondary line: "<plan> · Est. <date>" when both
        /// are available, falls through plan-only / est-only / email per
        /// `makeSubtitle`. Empty string when nothing meaningful to show;
        /// `profileRow` suppresses the second-line `Text` in that case.
        let subtitle: String
        let isActive: Bool
    }

    /// Group `profiles` by `providerID`, preserving `registry.all` order.
    /// Archived profiles are always dropped — switching to one would either
    /// fail (Claude refresh rejects archived) or silently reactivate a
    /// retired account. Providers with no remaining profiles → dropped.
    /// Profiles whose providerID isn't in the registry → dropped
    /// (e.g. a provider whose plugin was disabled at runtime). `isLive` lets callers hide profiles
    /// whose underlying CLI is not currently authenticated — defaults to
    /// "everything is live" so non-popover callers and earlier tests still
    /// behave the same.
    /// The summary an inactive row renders from. `.loaded` and `.stale` both
    /// carry a usable payload (stale is just a previous fetch shown dimmed);
    /// `.idle`/`.loading`/`.error` have none. Both the row's bar and its
    /// reset subtitle resolve through this so they always describe the *same*
    /// fetch — otherwise a stale row could paint a worst-model bar while the
    /// subtitle, computed from a different (nil) summary, fell back to an
    /// unrelated reset source.
    static func inactiveRowSummary(
        _ fetch: ProfileSwitcherFetchCoordinator.RowFetch
    ) -> ProviderUsageSummary? {
        switch fetch {
        case let .loaded(summary), let .stale(summary): return summary
        case .idle, .loading, .error: return nil
        }
    }

    @MainActor
    static func switcherSections(
        profiles: [Profile],
        registry: ProviderRegistry,
        activeID: UUID?,
        now: Date,
        isLive: (Profile) -> Bool = { _ in true },
        summaryFor: (UUID) -> ProviderUsageSummary? = { _ in nil }
    ) -> [Section] {
        registry.all.compactMap { provider in
            let matching = profiles.filter {
                $0.providerID == provider.id && $0.kind == .auto && isLive($0)
            }
            guard !matching.isEmpty else { return nil }
            let rows = matching.map { profile in
                // Switcher-specific estimate: the row text sits beside the
                // worst-model bar, so a provider (e.g. Antigravity) can favour
                // that model's own reset here so the text matches the bar,
                // rather than the account-level renewal shown in the header.
                let estimate = provider.switcherRenewalEstimate(
                    profile: profile, summary: summaryFor(profile.id), now: now)
                let datePart = estimate.map { RenewalEstimator.subtitleString($0, now: now) }
                let subtitle = Self.makeSubtitle(
                    plan: profile.subscriptionPlan,
                    datePart: datePart,
                    email: profile.email ?? "",
                    displayName: profile.resolvedDisplayName
                )
                return Row(
                    profileID: profile.id,
                    providerID: profile.providerID,
                    email: profile.email ?? "",
                    displayName: profile.resolvedDisplayName,
                    subtitle: subtitle,
                    isActive: profile.id == activeID
                )
            }
            return Section(
                providerID: provider.id,
                providerDisplayName: provider.displayName,
                providerIconAssetName: provider.iconAssetName,
                rows: rows
            )
        }
    }

    /// Builds the row's secondary line by priority:
    /// 1. plan + datePart → "<plan> · <datePart>"
    /// 2. plan only       → "<plan>"
    /// 3. datePart only   → "<datePart>"
    /// 4. neither + email != displayName → email (disambiguator)
    /// 5. neither + email == displayName / empty → "" (suppress the line)
    static func makeSubtitle(plan: String?, datePart: String?, email: String, displayName: String) -> String {
        switch (plan, datePart) {
        case let (plan?, date?):  return "\(plan) · \(date)"
        case let (plan?, nil):    return plan
        case let (nil, date?):    return date
        case (nil, nil):
            return (email.isEmpty || email == displayName) ? "" : email
        }
    }

    /// Flattens `[Section]` row-major and drops the active row (the
    /// header card carries it). Each row is paired with its provider
    /// icon asset so the list renderer doesn't need to re-look-up the
    /// section it came from. Counterpart to the instance-method
    /// `orderedRows(_:)` (which lifts active to the top); this one
    /// excludes active entirely and keeps the original section order.
    @MainActor
    static func orderedRowsExcludingActive(_ sections: [Section]) -> [(Row, String)] {
        var out: [(Row, String)] = []
        for section in sections {
            for row in section.rows where !row.isActive {
                out.append((row, section.providerIconAssetName))
            }
        }
        return out
    }

    /// "Live" = the profile's email matches whichever account the provider's
    /// CLI is currently authenticated as. Profiles for accounts whose token
    /// is in the keychain but whose CLI is no longer signed in stay in the
    /// store (Settings still surfaces them) but drop out of the picker
    /// — switching to them would fail at refresh time anyway.
    ///
    /// Pure static so tests can pin down case-insensitive matching without
    /// spinning up watchers; the email compare matches the rest of the
    /// codebase (ProfileStore.findMatching, AutoProfileCoordinator) which
    /// all use caseInsensitiveCompare.
    @MainActor
    static func isLive(
        profile: Profile,
        claudeCLIEmail: String?,
        codexCLIEmail: String?,
        antigravityProcessAlive: Bool = false
    ) -> Bool {
        // Antigravity's liveness signal is "the language_server process is
        // running on this machine" — not an email match, because the
        // identity that drives Antigravity profiles (CSRF + port) doesn't
        // carry email at create-time and the same email can be reused
        // across Antigravity app launches. The watcher's `current` is the
        // single source of truth for whether agy/Antigravity.app is up.
        if profile.providerID == .antigravity {
            return antigravityProcessAlive
        }
        guard let email = profile.email else { return false }
        func matches(_ other: String?) -> Bool {
            other?.caseInsensitiveCompare(email) == .orderedSame
        }
        switch profile.providerID {
        case .claude: return matches(claudeCLIEmail)
        case .codex:  return matches(codexCLIEmail)
        case .antigravity: return false
        }
    }

    /// Maps a profile's usage summary to the status-dot color shown on
    /// its avatar (header card for the active profile, list card for
    /// non-active rows). Returns nil when there's no data to display —
    /// callers omit the dot in that case so loading / pre-fetch states
    /// don't paint a misleading green.
    ///
    /// Delegates to `MenuBarUsageDriver` so the dot's palette, thresholds,
    /// and bucket selection are the same ones driving the menu-bar icon
    /// directly above it. Palette: green < 60, yellow < 80, red ≥ 80 (per
    /// `UsageLevel.tint`). Bucket: whichever the user picked via
    /// `MenuBarUsageSource` — `.session` reads only the primary bucket,
    /// `.weekly` only the secondary, `.higher` the max of the two. We
    /// still suppress the dot when the resolved utilization is nil so a
    /// "no data yet" state doesn't paint a misleading green.
    @MainActor
    static func quotaDotColor(for summary: ProviderUsageSummary?, source: MenuBarUsageSource) -> Color? {
        let reading = MenuBarUsageDriver.read(summary: summary, source: source)
        guard reading.utilization != nil else { return nil }
        return reading.tint
    }

    // MARK: View

    @State private var isExpanded: Bool = false

    /// Mirrors the AppStorage key that `MenuBarIconView` reads — both surfaces
    /// adopt the same per-user "which bucket drives the tint" choice. Updating
    /// the setting in Settings re-evaluates the dot color in the same SwiftUI
    /// tick as the menu-bar icon, no manual notification plumbing.
    @AppStorage(AppStorageKeys.generalMenuBarUsageSource)
    private var menuBarSourceRaw: String = MenuBarUsageSource.session.rawValue

    private var menuBarSource: MenuBarUsageSource {
        MenuBarUsageSource.resolve(menuBarSourceRaw)
    }

    @State private var coordinator: ProfileSwitcherFetchCoordinator? = nil
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let sections = currentSections()
        let liveRowCount = sections.reduce(0) { $0 + $1.rows.count }
        let canExpand = liveRowCount >= 2

        VStack(spacing: 8) {
            cardHeader(canExpand: canExpand)
            if isExpanded && canExpand {
                listCard(rows: Self.orderedRowsExcludingActive(sections))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                ensureCoordinator()
                coordinator?.reset()
                coordinator?.seed(vm.lastSummaryByProfile)
                let activeID = vm.profileStore.activeProfileId
                let profiles = sections.flatMap { $0.rows }.compactMap { row in
                    vm.profileStore.profiles.first(where: { $0.id == row.profileID })
                }
                Task { await coordinator?.startFetching(profiles: profiles, skip: activeID) }
            } else {
                coordinator?.reset()
            }
        }
    }

    private func currentSections() -> [Section] {
        let claudeEmail = vm.cliAccountWatcher.current?.email
        let codexEmail = vm.codexAccountWatcher.current?.email
        let antigravityAlive = vm.antigravityProcessWatcher.current != nil
        return Self.switcherSections(
            profiles: vm.profileStore.profiles,
            registry: vm.registry,
            activeID: vm.profileStore.activeProfileId,
            now: Date(),
            isLive: { profile in
                Self.isLive(
                    profile: profile,
                    claudeCLIEmail: claudeEmail,
                    codexCLIEmail: codexEmail,
                    antigravityProcessAlive: antigravityAlive
                )
            },
            summaryFor: { id in
                guard let coordinator else { return nil }
                return Self.inactiveRowSummary(coordinator.row(for: id))
            }
        )
    }

    @ViewBuilder
    private func cardHeader(canExpand: Bool) -> some View {
        if canExpand {
            Button {
                isExpanded.toggle()
            } label: {
                cardBody(trailingChevron: isExpanded ? "chevron.up" : "chevron.down")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            cardBody(trailingChevron: nil)
        }
    }

    private func cardBody(trailingChevron: String?) -> some View {
        let providerID = vm.profileStore.activeProfile?.providerID ?? .claude
        let iconAsset = vm.registry.provider(for: providerID)?.iconAssetName ?? "Mascot"
        return ProfileCardView(
            plan: vm.subscriptionPlan,
            renewalText: vm.subscriptionRenewalText,
            renewalTooltip: vm.subscriptionRenewalTooltip,
            activeProfileName: vm.profileStore.activeProfile?.name ?? "",
            iconAssetName: iconAsset,
            quotaDotColor: Self.quotaDotColor(for: vm.summary, source: menuBarSource),
            trailingSymbolName: trailingChevron
        )
    }

    @ViewBuilder
    private func listCard(rows: [(Row, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.element.0.profileID) { index, pair in
                profileRow(pair.0, iconAsset: pair.1)
                if index < rows.count - 1 {
                    // .opacity(0.3) matches the hairline style already
                    // used by AntigravityUsageDetailView's model rows.
                    Divider().opacity(0.3)
                }
            }
        }
        .kwotaCard()
    }

    @ViewBuilder
    private func profileRow(_ row: Row, iconAsset: String) -> some View {
        Button {
            switchTo(row.profileID)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                circularAvatar(name: iconAsset, size: 32, dotColor: rowDotColor(for: row))
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.displayName)
                        .font(.body)
                        .lineLimit(1)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                rowBars(for: row)
                    .frame(width: 160)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    /// Resolves the per-row dot color from the coordinator's snapshot.
    /// `.loaded` is the only state that paints a dot — `.idle`,
    /// `.loading`, and `.error` all suppress it so the user can tell
    /// "no data yet" apart from "data says you're fine".
    private func rowDotColor(for row: Row) -> Color? {
        let fetch = coordinator?.row(for: row.profileID) ?? .idle
        if case let .loaded(summary) = fetch {
            return Self.quotaDotColor(for: summary, source: menuBarSource)
        }
        return nil
    }

    @ViewBuilder
    private func rowBars(for row: Row) -> some View {
        // One geometry for every state. .loading → spinner trailing slot;
        // .loaded → percent text; .error → triangle with hover tooltip.
        // The bars themselves render dim (Color.secondary.gradient via the
        // `utilization == nil` path in barLine) for both .loading and
        // .error, so loading→error transitions don't shift layout.
        let fetch = coordinator?.row(for: row.profileID) ?? .idle
        let summary: ProviderUsageSummary? =
            row.isActive ? vm.summary : Self.inactiveRowSummary(fetch)
        let isStale: Bool = { if case .stale = fetch { return true } else { return false } }()
        let (primaryIcon, secondaryIcon) = Self.barIcons(for: row.providerID)

        // Provider-supplied tooltip and dim flags. Default-impl providers
        // (Claude, Codex) return (nil, nil) / (false, false) — barLine
        // then falls back to its built-in tooltip and utilization-color.
        let provider = vm.registry.provider(for: row.providerID)
        let tips: (primary: String?, secondary: String?) =
            summary.flatMap { provider?.switcherBarTooltips(summary: $0) } ?? (nil, nil)
        let dim: (primary: Bool, secondary: Bool) =
            summary.flatMap { provider?.switcherBarDimming(summary: $0) } ?? (false, false)

        VStack(alignment: .leading, spacing: 3) {
            barLine(
                iconName: primaryIcon,
                utilization: summary?.primary?.utilization,
                fetch: fetch,
                isActive: row.isActive,
                tooltip: tips.primary,
                forceDim: dim.primary || isStale
            )
            barLine(
                iconName: secondaryIcon,
                utilization: summary?.secondary?.utilization,
                fetch: fetch,
                isActive: row.isActive,
                tooltip: tips.secondary,
                forceDim: dim.secondary || isStale
            )
        }
    }

    /// Per-provider SF Symbol pair rendered as the leading icon for each
    /// of the two utilization bars on a switcher row. Returning symbol
    /// names (not text labels) keeps the bar column compact and lets
    /// the row's `.help(tooltip)` handler carry the full semantic on
    /// hover.
    ///
    /// - Claude / Codex: `clock` (5-hour rolling) and `calendar`
    ///   (weekly) — both share the same time-window shape.
    /// - Antigravity: `cube` (worst-model rate-limit) and `creditcard`
    ///   (AI Credits wallet).
    static func barIcons(for providerID: ProviderID) -> (String, String) {
        switch providerID {
        case .antigravity:
            return ("cube", "creditcard")
        case .claude, .codex:
            return ("clock", "calendar")
        }
    }

    @ViewBuilder
    private func barLine(
        iconName: String,
        utilization: Double?,
        fetch: ProfileSwitcherFetchCoordinator.RowFetch,
        isActive: Bool,
        tooltip: String? = nil,
        forceDim: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            // 18pt leading cell: SF Symbol replaces the 3-char text
            // label. Tooltip on the outer HStack (below) carries the
            // full semantic — the icon is glanceable shorthand only.
            Image(systemName: iconName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            // UsageBucket.utilization is in the 0-100 range across the app
            // (Claude does util * 100; Codex passes usedPercent verbatim,
            // see CodexProvider.swift:93-96). The bar renders in
            // **battery view**: width = 100 − utilization, so a fresh
            // window starts at full width and drains as the user consumes.
            // Color is still driven by utilization via UsageLevel.tint(for:)
            // so a near-empty bar fires red at the same threshold the
            // PerModelCard / popover quota bars use — bar visuals share
            // one threshold dialect across the popover and the switcher.
            // `forceDim` overrides that color with the dim grey gradient
            // so a provider can request "data is fine but inactive"
            // rendering (e.g. Antigravity AI Credits when overages are off).
            Chart {
                BarMark(
                    xStart: .value("Start", 0),
                    xEnd:   .value("End", utilization.map { 100 - $0 } ?? 0),
                    y:      .value("Track", "")
                )
                .foregroundStyle(
                    (forceDim || utilization == nil
                        ? Color.secondary
                        : UsageLevel.tint(for: utilization)
                    ).gradient
                )
                .cornerRadius(4)
            }
            .chartXScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { plot in
                plot
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 8)
            // 32pt leading-aligned column: "12%" / "100%" sit flush
            // against the bar's tail instead of drifting to the row
            // edge in a 42pt right-aligned slot.
            trailingIndicator(utilization: utilization, fetch: fetch, isActive: isActive)
                .frame(width: 32, alignment: .leading)
        }
        // Tooltip on the outer HStack: hovering the icon, the chart,
        // OR the trailing percent slot all reveal the provider-supplied
        // tooltip. Uses a custom `.onHover` + overlay tooltip instead of
        // SwiftUI's `.help` — `.help` is OS-managed and waits ~2 seconds
        // before showing, which is too sluggish for a glanceable switcher
        // chrome where the user is already mousing over the bar to read
        // the percentage. Custom path fires at 200ms.
        .modifier(SwitcherBarTooltipModifier(text: tooltip))
    }

    /// Lightweight hover tooltip used by the switcher bars. Replaces
    /// SwiftUI's `.help` to bypass its ~2-second built-in delay — the
    /// switcher needs near-immediate feedback because the user is
    /// already deliberately hovering the bar to read the percentage.
    ///
    /// Behavior:
    ///   - Spawns a 200ms Task on hover-in; the tooltip only appears
    ///     after the cursor stays put. This stops drag-by hovers from
    ///     flashing tooltips as the user moves between rows.
    ///   - Cancels the pending task on hover-out so a quick brush
    ///     never reveals.
    ///   - Renders as a small caption-text bubble offset 32pt above
    ///     the bar (regular material + secondary stroke). Empty/nil
    ///     text leaves no overlay AND no hover handler, matching the
    ///     prior `.help`-conditional defensiveness.
    private struct SwitcherBarTooltipModifier: ViewModifier {
        let text: String?
        private static let showDelay: Duration = .milliseconds(200)
        @State private var isShowing = false
        @State private var pendingTask: Task<Void, Never>?

        /// Single-line width of `text` at the caption font, capped so the
        /// padded bubble stays inside the 400pt popover when centered over the
        /// bar. Text under the cap hugs its exact width (no trailing dead space);
        /// longer text is capped here and wraps via the vertical `fixedSize`.
        /// The small fudge absorbs sub-pixel differences between the measured and
        /// rendered caption font so text that should fit isn't wrapped early.
        private static func bubbleTextWidth(_ text: String) -> CGFloat {
            // Cap leaves room for the bubble (text + 16 padding) plus edge margins
            // inside the popover; clamping handles position, this handles wrapping
            // the genuinely long ones.
            let cap: CGFloat = 340
            let font = NSFont.preferredFont(forTextStyle: .caption1)
            let ideal = (text as NSString).size(withAttributes: [.font: font]).width
            return min(ceil(ideal) + 8, cap)
        }

        /// Horizontal offset, from the bar's leading edge, that keeps the
        /// `bubbleWidth`-wide tooltip centered over the bar but fully inside the
        /// popover — shifting it in from whichever edge it would otherwise spill
        /// past. Inputs are in the popover coordinate space.
        private static func clampedOffsetX(barMinX: CGFloat, barWidth: CGFloat, bubbleWidth: CGFloat) -> CGFloat {
            // Inset from the popover edge so the bubble clears the card's rounded
            // edge with a visible gap rather than hugging the very edge.
            let margin: CGFloat = 18
            let popoverW = MenuBarView.popoverWidth
            let desiredLeading = barMinX + barWidth / 2 - bubbleWidth / 2
            let maxLeading = max(margin, popoverW - bubbleWidth - margin)
            let clampedLeading = min(max(margin, desiredLeading), maxLeading)
            return clampedLeading - barMinX
        }

        @ViewBuilder
        private func bubble(_ text: String) -> some View {
            Text(text)
                .font(.caption)
                .multilineTextAlignment(.center)
                .frame(width: Self.bubbleTextWidth(text), alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2))
                )
        }

        func body(content: Content) -> some View {
            // Skip the whole hover machinery when there's nothing to show —
            // avoids registering an idle hover region that would compete
            // with sibling targets for cursor capture.
            if let text, !text.isEmpty {
                content
                    .onHover { hovering in
                        pendingTask?.cancel()
                        if hovering {
                            pendingTask = Task { @MainActor in
                                try? await Task.sleep(for: Self.showDelay)
                                if !Task.isCancelled {
                                    isShowing = true
                                }
                            }
                        } else {
                            isShowing = false
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if isShowing {
                            // The bubble hugs its measured single-line width, then
                            // is shifted (via the popover coordinate space) so it
                            // stays centered over the bar yet fully inside the
                            // popover — the bar sits off-centre, so a plain centered
                            // overlay would spill past the popover edge and clip.
                            GeometryReader { geo in
                                let bar = geo.frame(in: .named(MenuBarView.popoverCoordinateSpace))
                                let bubbleW = Self.bubbleTextWidth(text) + 16   // + horizontal padding
                                let dx = Self.clampedOffsetX(
                                    barMinX: bar.minX, barWidth: bar.width, bubbleWidth: bubbleW)
                                bubble(text)
                                    .offset(x: dx, y: -32)
                            }
                            .allowsHitTesting(false)
                            .transition(.opacity)
                            .zIndex(1000)
                        }
                    }
                    .animation(.easeOut(duration: 0.1), value: isShowing)
            } else {
                content
            }
        }
    }

    /// Trailing column body: percent text for loaded/idle/active states,
    /// circular spinner for the .loading state, triangle with hover
    /// tooltip for the .error state. The 32pt fixed-width frame lives
    /// at the call site, so the column geometry is the same regardless
    /// of which branch this builder returns.
    @ViewBuilder
    private func trailingIndicator(utilization: Double?, fetch: ProfileSwitcherFetchCoordinator.RowFetch, isActive: Bool) -> some View {
        // Trailing percent reads as REMAINING (= 100 − utilization) so it
        // matches the bar's battery-view direction: bar full + "100%" =
        // healthy, bar small + "5%" = near the cap.
        if isActive, let u = utilization {
            Text("\(Int((100 - u).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            switch fetch {
            case .idle:
                Text("—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .loading:
                // Native indeterminate spinner. .controlSize(.small) +
                // 0.6 scale lands the indicator near ~9pt diameter,
                // visually balanced against the 8pt bar. No text means
                // no glyph-width difference between "loading…" and "20%"
                // that produced the perceived column jitter.
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            case .loaded:
                if let u = utilization {
                    Text("\(Int((100 - u).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            case .error(let message):
                // Triangle in the trailing slot keeps the two-bar
                // layout stable across loading→error transitions. The
                // full message ("Sign in to load usage", "Account
                // mismatch — switch profile", "Couldn't load usage") is
                // reachable via the native macOS hover tooltip.
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(message)
            case .stale(let s):
                if let u = utilization {
                    Text("\(Int((100 - u).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .help("Couldn't refresh · as of \(RelativeTimeText.format(from: s.fetchedAt, to: Date()))")
                } else {
                    Text("—")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .help("Couldn't refresh · as of \(RelativeTimeText.format(from: s.fetchedAt, to: Date()))")
                }
            }
        }
    }

    private func ensureCoordinator() {
        if coordinator == nil {
            coordinator = ProfileSwitcherFetchCoordinator(
                fetcher: vm.profileUsageFetcher,
                store: SwitcherSummaryStore(),
                // Row 429 propagates Retry-After into the active path's
                // per-provider back-off floor. Default to 60s when the
                // server omits the header — matches the popover-open tick
                // cadence so the next /api/oauth/usage call is naturally
                // delayed past one bucket-refill window. Scoped to the
                // row's providerID so a Claude 429 doesn't poison the
                // Codex / Antigravity floors.
                onRowRateLimited: { [weak vm] providerID, retryAfter in
                    vm?.refreshCoordinator?.applyRetryAfter(retryAfter ?? 60, for: providerID)
                },
                // Switcher row fetches consult the per-provider back-off
                // floor before firing. Claude 429 blocks Claude rows;
                // Antigravity (loopback, no rate limit) is never gated
                // by Claude / Codex floors — see UsageRefreshCoordinator
                // for the per-provider storage.
                isExternallyBackingOff: { [weak vm] providerID in
                    guard let until = vm?.refreshCoordinator?.backoffUntil(for: providerID) else {
                        return false
                    }
                    return until > Date()
                }
            )
        }
    }

    private func switchTo(_ id: UUID) {
        // Capture the coordinator's cached summary BEFORE setActive
        // (which clears vm.summary via onActiveProfileChange). If the
        // row is already .loaded, we have data in hand — hand it to the
        // VM right after the active-profile flip so the chart renders
        // immediately while the background refresh runs.
        let preload: ProviderUsageSummary? = {
            if case let .loaded(s) = coordinator?.row(for: id) ?? .idle {
                return s
            }
            return nil
        }()
        do {
            try vm.profileStore.setActive(id: id)
            if let preload {
                vm.adoptPreloadedSummary(preload)
            }
            isExpanded = false
            coordinator?.reset()
        } catch {
            AppLog.shared.log(
                "ProfileSwitcherCard: setActive failed: \(error)",
                level: .error
            )
        }
    }

    /// Wraps `providerIcon` inside a tinted circular background with a
    /// 1pt ring, mirroring the header card's avatar treatment. The icon
    /// is inscribed at ~60% of the outer diameter; the optional dot
    /// renders on the outer Circle's southeast perimeter (offset -1/-1
    /// from .bottomTrailing).
    @ViewBuilder
    private func circularAvatar(name: String, size: CGFloat, dotColor: Color?) -> some View {
        let innerSize = floor(size * 0.6)
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            providerIcon(name, size: innerSize)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
                    .offset(x: -1, y: -1)
            }
        }
    }

    /// `iconAssetName` may be an asset catalog entry (e.g. "Mascot",
    /// "CodexLogo") or an SF Symbol. Try the asset first; SF Symbol
    /// fallback handles providers that ship without a bundled image.
    /// `size` defaults to 16pt so any future caller stays at today's
    /// inline-glyph size; the switcher's profileRow passes 32pt.
    @ViewBuilder
    private func providerIcon(_ name: String, size: CGFloat = 16) -> some View {
        if NSImage(named: name) != nil {
            Image(name)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: name)
                .frame(width: size, height: size)
        }
    }
}
