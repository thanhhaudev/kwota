//
//  CacheTabView.swift
//  Kwota
//
//  Popover Cache tab. Real-data backed: `CacheCleaner.scan` populates
//  sizes, `CacheCleaner.clean` (Trash) handles Clean now, the AI evaluator
//  fills `aiEvaluation`. All persisted state hangs off
//  `MenuBarViewModel.cacheState`.
//

import AppKit
import SwiftUI

struct CacheTabView: View {
    let vm: MenuBarViewModel
    @State private var showAllRows: Bool = false
    /// Inline confirms (an alert would close the MenuBarExtra popover —
    /// same pattern as the Awake tab's kill confirm).
    @State private var confirmingCleanNow = false
    @State private var confirmingDeleteRowID: UUID?
    /// Row whose AI detail sheet is currently open. nil hides the sheet.
    @State private var aiDetailRowID: UUID?
    /// Cached upper bound for the scrollable folder list. Resolved once on
    /// view appear (and on `didChangeScreenParameters`) so SwiftUI doesn't
    /// re-query `NSScreen.main` every body re-render — display config
    /// rarely changes, polling it from the view tree was wasted work.
    @State private var maxListHeight: CGFloat = 540

    /// Rows under this size are folded into the "Show N more" tail by default.
    private let minorThreshold: Int = 1_000_000_000  // 1 GB (decimal — matches formatter)

    /// All row-derived values for one render, from a single filter+sort pass.
    /// The previous per-property computeds each re-ran the filter+sort, so a
    /// body evaluation sorted the rows 6–8 times; `makeRowsModel()` does it
    /// once and `body` threads the result into the subviews.
    private struct RowsModel {
        let sorted: [CachePathRow]
        let major: [CachePathRow]
        let minor: [CachePathRow]
        let totalBytes: Int
        let unevaluatedCount: Int

        var canToggleTail: Bool { !major.isEmpty && !minor.isEmpty }

        /// When the whole list is small (no row >= 1 GB), flatten to the full
        /// sorted list — no point hiding tiny rows behind a toggle.
        func visible(showAll: Bool) -> [CachePathRow] {
            if major.isEmpty { return sorted }
            return showAll ? sorted : major
        }
    }

    /// Hide rows with no content from the popover. Zero-byte rows after a
    /// clean are pure visual noise — they're still managed in Settings →
    /// Cache, so users haven't lost access to them. Helper-managed (catalog
    /// system) rows are hidden entirely when the privileged helper is
    /// unsupported (ad-hoc build) — they could never be sized or cleaned.
    private func makeRowsModel() -> RowsModel {
        let helperSupported = vm.privilegedHelper.isSupported
        let sorted = vm.cacheState.rows
            .filter { $0.exists && $0.sizeBytes > 0 && (helperSupported || !$0.isHelperManaged) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
        return RowsModel(
            sorted: sorted,
            major: sorted.filter { $0.sizeBytes >= minorThreshold },
            minor: sorted.filter { $0.sizeBytes < minorThreshold },
            totalBytes: sorted.reduce(0) { $0 + $1.sizeBytes },
            // Only count existing, non-empty rows — no value in pushing the
            // LLM to evaluate folders the user can't currently see.
            unevaluatedCount: sorted.filter { $0.aiEvaluation == nil }.count
        )
    }

    /// Total bytes the Clean-now button will free — sum of every auto-on
    /// row with content. Independent of the cap so manual cleanup is always
    /// available even when under-cap (the cap only gates auto-triggered runs).
    private var cleanableBytes: Int {
        vm.cacheState.rows
            .filter {
                $0.exists && $0.autoCleanEnabled && $0.sizeBytes > 0
                    && (vm.privilegedHelper.isSupported || !$0.isHelperManaged)
            }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        let model = makeRowsModel()
        return VStack(alignment: .leading, spacing: 10) {
            CacheStatusBar(
                totalBytes: model.totalBytes,
                capBytes: vm.cacheState.settings.globalCapBytes,
                isAutoCleanEnabled: vm.cacheState.settings.isEnabled
            )

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Cache Breakdown")
                folderListCard(model)
                    .frame(maxHeight: maxListHeight, alignment: .top)
            }

            CacheFooterBar(
                cleanableBytes: cleanableBytes,
                isRescanning: vm.cacheState.isScanning || vm.cacheState.isCleaning,
                isEvaluatingAI: vm.cacheState.isEvaluatingAll,
                unevaluatedCount: model.unevaluatedCount,
                onCleanNow: { confirmingCleanNow = true },
                onRescan: { Task { await vm.cacheScan(force: true) } },
                onEvaluateAll: { vm.cacheEvaluateAllWithAI() }
            )
            .padding(.horizontal, 2)
            // Anchored confirm bubble — same .popover survival trick as the
            // AI-detail popovers below (alerts/sheets dismiss the popover).
            .popover(isPresented: $confirmingCleanNow, arrowEdge: .bottom) {
                if let plan = vm.cacheCleanNowPlan {
                    KwotaConfirmPopover(
                        title: plan.permanent
                            ? "Permanently delete \(plan.count) folder\(plan.count == 1 ? "" : "s")?"
                            : "Clean \(plan.count) folder\(plan.count == 1 ? "" : "s")?",
                        message: plan.permanent
                            ? "\(plan.totalBytes.formattedBytes) will be permanently deleted and cannot be recovered."
                            : "\(plan.totalBytes.formattedBytes) will be moved to the Trash. You can recover items from Finder until the Trash is emptied.",
                        destructiveTitle: plan.permanent ? "Delete" : "Clean",
                        onConfirm: {
                            confirmingCleanNow = false
                            vm.cacheCleanNowConfirmed()
                        },
                        onCancel: { confirmingCleanNow = false }
                    )
                }
            }

            if let risky = vm.cacheRiskyNotice {
                KwotaInlineAlert(
                    tint: .red,
                    icon: "exclamationmark.octagon.fill",
                    title: "Folders flagged risky",
                    detail: risky,
                    actionTitle: "Dismiss",
                    onAction: { vm.cacheDismissRiskyNotice() }
                )
            }

            if let error = vm.cacheState.aiEvaluationError {
                let display = aiErrorDisplay(for: error)
                KwotaInlineAlert(
                    tint: display.tint,
                    icon: display.icon,
                    title: display.title,
                    detail: display.detail,
                    actionTitle: "Dismiss",
                    onAction: { vm.cacheDismissAIEvaluationError() }
                )
            }
            if let error = vm.cacheState.systemCleanError {
                let display = Self.systemCleanErrorDisplay(for: error)
                KwotaInlineAlert(
                    tint: display.tint,
                    icon: display.icon,
                    title: display.title,
                    detail: display.detail,
                    actionTitle: "Dismiss",
                    onAction: { vm.cacheDismissSystemCleanError() }
                )
            }
            if let error = vm.cacheState.normalCleanError {
                KwotaInlineAlert(
                    tint: .orange,
                    icon: "exclamationmark.triangle.fill",
                    title: "Cache clean failed",
                    detail: error,
                    actionTitle: "Dismiss",
                    onAction: { vm.cacheDismissNormalCleanError() }
                )
            }
        }
        // Interval-gated initial scan. `.task` cancels automatically when
        // the popover closes, so we don't leak a long-running scan if the
        // user dismisses mid-enumeration; the next open will retry. `force:
        // false` means a second open within `scanInterval` reuses the
        // previous result and skips re-scanning.
        .task {
            await vm.cacheScan(force: false)
        }
        .onAppear { recomputeMaxListHeight() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            recomputeMaxListHeight()
        }
    }

    /// Map an `EvaluationError` to its inline-banner copy. Kept here (not on
    /// the error type itself) because tint + icon are SwiftUI concerns the
    /// service layer shouldn't know about.
    private func aiErrorDisplay(
        for error: CacheEvaluator.EvaluationError
    ) -> (tint: Color, icon: String, title: String, detail: String) {
        switch error {
        case .cliNotInstalled:
            return (
                .orange,
                "terminal",
                "Claude Code CLI not found",
                "AI evaluation runs through the `claude` command. Install Claude Code, sign in, then try again."
            )
        case .cliFailed(let stderr):
            return (
                .red,
                "exclamationmark.triangle",
                "Claude CLI returned an error",
                "Re-run `claude` once to verify your session, then try again. (\(Self.truncatedForBanner(stderr)))"
            )
        case .timeout:
            return (
                .orange,
                "clock.badge.exclamationmark",
                "Claude CLI took too long",
                "The evaluation ran past its time budget. Try again, or re-evaluate one row at a time."
            )
        case .parseFailed(let message):
            return (
                .red,
                "doc.questionmark",
                "Couldn't parse Claude's response",
                "The model didn't return valid JSON. Try again. (\(Self.truncatedForBanner(message)))"
            )
        }
    }

    /// Inline-banner copy for a privileged-helper failure during a manual
    /// system-cache clean.
    private static func systemCleanErrorDisplay(
        for error: PrivilegedHelperError
    ) -> (tint: Color, icon: String, title: String, detail: String) {
        switch error {
        case .helperUnavailable:
            return (
                .orange,
                "lock.shield",
                "Privileged helper not installed",
                "System caches need the privileged helper. Install it in Settings › Cache › Privileged helper, then try again."
            )
        case .connectionFailed(let message):
            return (
                .red,
                "bolt.horizontal.circle",
                "Couldn't reach the privileged helper",
                "The helper didn't respond. Try removing and reinstalling it in Settings. (\(truncatedForBanner(message)))"
            )
        case .cleanFailed(let message):
            return (
                .red,
                "exclamationmark.triangle",
                "System cache clean failed",
                "The helper reported an error while deleting. (\(truncatedForBanner(message)))"
            )
        }
    }

    /// Keep stderr / decoder messages short enough for the banner caption
    /// — anything beyond ~120 chars wraps awkwardly inside the popover.
    /// Full text still lives in `AppLog` for diagnostics.
    private static func truncatedForBanner(_ s: String) -> String {
        let max = 120
        if s.count <= max { return s }
        return s.prefix(max) + "…"
    }

    private func recomputeMaxListHeight() {
        // Same formula as the previous computed property — extracted so we
        // only run it on demand instead of every body evaluation. 540pt
        // hard cap keeps the popover a "summary" surface rather than a
        // window; ~250pt reserved for tab bar, header, footer, popover
        // chrome.
        let screenH = NSScreen.main?.visibleFrame.height ?? 900
        maxListHeight = min(540, max(240, screenH * 0.85 - 250))
    }

    private func folderListCard(_ model: RowsModel) -> some View {
        let visible = model.visible(showAll: showAllRows)
        // Computed from the FULL row list (not `visible`) so the scope pill
        // is stable even when the colliding partner row is hidden by the
        // "Show All" toggle.
        let scopeCollisions = CachePathRow.scopeCollisionNames(in: vm.cacheState.rows)
        // Card chrome is inlined here (instead of `.kwotaCard()`) so the tail
        // toggle can sit as a non-scrolling footer row inside the rounded
        // card, separated from the scrolling rows by a hairline divider —
        // the same pattern System Settings uses for "Show All" rows.
        return VStack(spacing: 0) {
            ScrollView {
                // LazyVStack (not VStack): expanding the tail can reveal 5–15
                // rows at once, and each row is a heavy subtree (a `Menu` plus
                // an attached `.popover`). A plain VStack builds them all
                // synchronously on first expand, freezing the popover for
                // 1–3s. Lazy realization builds only the rows near the
                // viewport and defers the rest until scrolled into view.
                LazyVStack(alignment: .leading, spacing: 0) {
                    if visible.isEmpty {
                        emptyOrLoadingPlaceholder
                    } else {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { idx, row in
                            if idx > 0 {
                                Divider().opacity(0.35)
                            }
                            CacheRowView(
                                row: row,
                                showsUserScopePill: !row.isSystem
                                    && scopeCollisions.contains(row.displayName),
                                isReEvaluating: vm.cacheState.evaluatingRowIDs.contains(row.id),
                                isCleaning: vm.cacheState.cleaningRowIDs.contains(row.id),
                                onCleanNow: {
                                    if vm.cacheDeleteIsPermanent {
                                        confirmingDeleteRowID = row.id
                                    } else {
                                        vm.cacheCleanRow(rowID: row.id)
                                    }
                                },

                                onReEvaluate: { vm.cacheReEvaluateRow(rowID: row.id) },
                                onToggleAuto: { vm.cacheToggleAuto(rowID: row.id) },
                                onReveal: { vm.cacheRevealInFinder(rowID: row.id) },
                                onCopyPath: { vm.cacheCopyPath(rowID: row.id) },
                                onRemove: { vm.cacheRemoveRow(rowID: row.id) },
                                onShowAIDetail: { aiDetailRowID = row.id }
                            )
                            .popover(
                                isPresented: Binding(
                                    get: { confirmingDeleteRowID == row.id },
                                    set: { if !$0 { confirmingDeleteRowID = nil } }
                                ),
                                attachmentAnchor: .rect(.bounds),
                                arrowEdge: .trailing
                            ) {
                                KwotaConfirmPopover(
                                    title: "Permanently delete \(row.displayName)?",
                                    message: "\(row.sizeBytes.formattedBytes) will be permanently deleted and cannot be recovered.",
                                    destructiveTitle: "Delete",
                                    onConfirm: {
                                        confirmingDeleteRowID = nil
                                        vm.cacheCleanRow(rowID: row.id)
                                    },
                                    onCancel: { confirmingDeleteRowID = nil }
                                )
                            }
                            // `.popover` lives on each row (instead of on the
                            // tab root) so its arrow anchors to the row that
                            // was clicked — vertical position tracks the row,
                            // not the center of the tab. `.sheet` is avoided
                            // because sheets inside an NSPopover-backed
                            // MenuBarExtra lose focus to the parent popover
                            // and dismiss the whole thing.
                            .popover(
                                isPresented: Binding(
                                    get: { aiDetailRowID == row.id },
                                    set: { if !$0 { aiDetailRowID = nil } }
                                ),
                                attachmentAnchor: .rect(.bounds),
                                arrowEdge: .trailing
                            ) {
                                CacheAIDetailSheet(
                                    row: row,
                                    isReEvaluating: vm.cacheState.evaluatingRowIDs.contains(row.id),
                                    onReEvaluate: { vm.cacheReEvaluateRow(rowID: row.id) },
                                    onDismiss: { aiDetailRowID = nil }
                                )
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            }
            // Zero ScrollView's default top inset so SectionHeader's
            // `.padding(.bottom, 6)` is the only header→card separation,
            // matching the Usage tab.
            .contentMargins(0, for: .scrollContent)

            if model.canToggleTail {
                Divider()
                tailToggle(minorCount: model.minor.count)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
    }

    /// Shown in place of the folder rows when `visibleRows` is empty. Three
    /// distinct cases the user can land in:
    ///   • Scan in flight, no prior data → spinner + "Scanning cache…"
    ///   • Scan complete, every folder was empty → "All tracked folders are
    ///     empty." (the post-clean steady state)
    ///   • Pre-scan idle (lastScannedAt == nil and not yet scanning) → same
    ///     loading copy; the `.task` modifier kicks in within a frame so
    ///     this state is essentially instantaneous in practice.
    @ViewBuilder
    private var emptyOrLoadingPlaceholder: some View {
        if vm.cacheState.isScanning || vm.cacheState.lastScannedAt == nil {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning cache…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("All tracked folders are empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Bottom-anchored footer row inside the card. Plain link-style button —
    /// no material backdrop, no shadow — matching the native macOS
    /// "Show All / Manage…" pattern from System Settings.
    private func tailToggle(minorCount: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                showAllRows.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: showAllRows ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                if showAllRows {
                    Text("Hide \(minorCount) small folders")
                } else {
                    Text("\(minorCount) more under 1 GB")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}
