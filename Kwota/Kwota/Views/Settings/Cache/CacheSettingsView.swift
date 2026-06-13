//
//  CacheSettingsView.swift
//  Kwota
//
//  Settings → Cache. Config UI backed by `MenuBarViewModel.cacheState`.
//  Mutations flow through `cacheUpdate(settings:)` / `cacheSetAIModel(_:)`
//  so they hit disk via `CachePersistenceStore` on the way out.
//

import SwiftUI
import AppKit

struct CacheSettingsView: View {
    @Bindable var vm: MenuBarViewModel
    @State private var pendingAddURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroupedSection(
                    caption: "Auto-clean",
                    footer: "When background scan finds total tracked size above the cap, Kwota deletes auto-enabled folders to bring usage back under the cap."
                ) {
                    autoCleanRows
                }

                SettingsGroupedSection(
                    caption: "AI evaluation",
                    footer: "Kwota asks the selected AI engine to evaluate each tracked folder's safety. Evaluations consume that engine's subscription quota. Results are cached so the same folder isn't re-evaluated on every popover open."
                ) {
                    aiEvaluationRows
                }

                // Hidden on ad-hoc builds: without a team identifier the
                // helper's signing gate can never accept the app, so every
                // affordance here would be a dead end.
                if vm.privilegedHelper.isSupported {
                    SettingsGroupedSection(
                        caption: "Privileged helper",
                        footer: "System caches (e.g. the icon services cache) are owned by macOS. Kwota cleans them through a small helper that runs with elevated privileges. Installing it asks for approval once; after that, cleaning — including background auto-clean — runs without prompts. System caches are always deleted permanently."
                    ) {
                        privilegedHelperRows
                    }
                }

                SettingsGroupedSection(
                    caption: "Tracked folders",
                    footer: "Auto-clean only runs on rows you turn on. Folders outside your home directory are tracked for size only — Kwota can't clean them."
                ) {
                    trackedFoldersRows
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task {
            // Status only matters when the helper section is visible.
            guard vm.privilegedHelper.isSupported else { return }
            await vm.privilegedHelper.refreshStatus()
        }
    }

    // MARK: - AI evaluation section

    @ViewBuilder
    private var aiEvaluationRows: some View {
        SettingsRow(
            title: "Engine",
            subtitle: engineSubtitle
        ) {
            CompactInlinePicker(
                selection: Binding(
                    get: { vm.cacheState.aiEngine },
                    set: { vm.cacheSetAIEngine($0) }
                ),
                options: CacheAIEngine.allCases,
                title: { $0.displayName }
            )
        }
        SettingsSectionDivider()
        // One row, two option sets: the picker swaps with the engine while
        // each engine's model choice survives a round-trip (state keeps
        // both fields).
        if vm.cacheState.aiEngine == .claude {
            SettingsRow(
                title: "Model",
                subtitle: vm.cacheState.aiModel.caption
            ) {
                CompactInlinePicker(
                    selection: Binding(
                        get: { vm.cacheState.aiModel },
                        set: { vm.cacheSetAIModel($0) }
                    ),
                    options: AIModelChoice.allCases,
                    title: { $0.displayName }
                )
            }
        } else if vm.cacheState.aiEngine == .codex {
            SettingsRow(
                title: "Model",
                subtitle: vm.cacheState.aiCodexModel.caption
            ) {
                CompactInlinePicker(
                    selection: Binding(
                        get: { vm.cacheState.aiCodexModel },
                        set: { vm.cacheSetCodexModel($0) }
                    ),
                    options: CodexModelChoice.allCases,
                    title: { $0.displayName }
                )
            }
        }
        // .antigravity: no Model row — agy has no model selection.
        SettingsSectionDivider()
        SettingsRow(
            title: "Output language",
            subtitle: "Language the AI uses for purpose/warning/detail text. Kwota's UI stays in English."
        ) {
            CompactInlinePicker(
                selection: Binding(
                    get: { vm.cacheState.settings.aiLanguage },
                    set: { vm.cacheUpdate(settings: vm.cacheState.settings.with(aiLanguage: $0)) }
                ),
                options: CacheAILanguage.allCases,
                title: { $0.displayName }
            )
        }
        SettingsSectionDivider()
        SettingsRow(
            title: "Re-evaluate all",
            subtitle: "Drop cached evaluations and re-run on next popover open. \(aiCacheSummary)"
        ) {
            Button("Clear cache") {
                vm.cacheClearAIEvaluations()
            }
            .controlSize(.small)
        }
        #if DEBUG
        SettingsSectionDivider()
        // Debug-only: stays in dev builds so the alert copy can be
        // re-reviewed when we tweak it; release builds don't ship the
        // affordance.
        SettingsRow(
            title: "Preview risky alert",
            subtitle: "Fires the same NSAlert the real evaluator surfaces when AI verdicts come back risky. Debug-only — uses two demo paths from the current row list."
        ) {
            Button("Show preview") {
                vm.cacheFireRiskyAlertDemo()
            }
            .controlSize(.small)
        }
        #endif
    }

    private var aiCacheSummary: String {
        let evaluated = vm.cacheState.rows.filter { $0.aiEvaluation != nil }.count
        let total = vm.cacheState.rows.count
        if evaluated == 0 {
            return "No evaluations cached yet."
        }
        return "Currently \(evaluated) of \(total) tracked folder\(total == 1 ? "" : "s") evaluated."
    }

    private var engineSubtitle: String {
        switch vm.cacheState.aiEngine {
        case .claude:
            return "Evaluations run through the claude CLI and consume your Claude subscription quota."
        case .codex:
            return "Evaluations run through the codex CLI and consume your ChatGPT subscription quota."
        case .antigravity:
            return "Evaluations run through the agy CLI and consume your Antigravity subscription quota."
        }
    }

    // MARK: - Auto-clean section

    @ViewBuilder
    private var autoCleanRows: some View {
        SettingsRow(
            title: "Enable background scanning",
            subtitle: "Periodically check tracked folders and clean when the cap is exceeded."
        ) {
            // Route through `cacheUpdate` so the change persists and (if the
            // master switch turns on) the scheduler restarts on the next
            // tick. Writing `vm.cacheState.settings.isEnabled` directly
            // skipped both.
            Toggle("Enable background scanning", isOn: Binding(
                get: { vm.cacheState.settings.isEnabled },
                set: { vm.cacheUpdate(settings: vm.cacheState.settings.with(isEnabled: $0)) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        SettingsSectionDivider()
        SettingsRow(
            title: "Scan interval",
            subtitle: "How often Kwota measures folder sizes in the background."
        ) {
            CompactInlinePicker(
                selection: Binding(
                    get: { vm.cacheState.settings.scanInterval },
                    set: { vm.cacheUpdate(settings: vm.cacheState.settings.with(scanInterval: $0)) }
                ),
                options: AutoCleanSettings.ScanInterval.allCases,
                title: { $0.label }
            )
            .disabled(!vm.cacheState.settings.isEnabled)
        }
        SettingsSectionDivider()
        SettingsRow(
            title: "Global size cap",
            subtitle: "Clean when total tracked size exceeds this value."
        ) {
            globalCapControl
        }
        SettingsSectionDivider()
        SettingsRow(
            title: "Delete permanently",
            subtitle: "Skip the Trash — cleaning deletes files outright and reclaims disk space immediately. Irreversible. Off by default; enabling asks for confirmation."
        ) {
            // `cacheSetDeletePermanently` gates the on-transition behind an
            // NSAlert; if the user cancels, the setting is untouched and
            // this toggle springs back off on the next render.
            Toggle("Delete permanently", isOn: Binding(
                get: { vm.cacheState.settings.deletePermanently },
                set: { vm.cacheSetDeletePermanently($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        // Moot when permanent-delete is on — nothing reaches the Trash, so
        // hide the row entirely rather than show a disabled picker.
        if !vm.cacheState.settings.deletePermanently {
            SettingsSectionDivider()
            SettingsRow(
                title: "Auto-empty Trash",
                subtitle: "Permanently delete items Kwota moved to Trash after this many days. Other items in your Trash are never touched. Off by default — items linger until you empty Finder Trash manually."
            ) {
                CompactInlinePicker(
                    selection: Binding(
                        get: { vm.cacheState.settings.autoEmptyTrashAfterDays },
                        set: { vm.cacheUpdate(settings: vm.cacheState.settings.with(autoEmptyTrashAfterDays: $0)) }
                    ),
                    options: Self.autoEmptyTrashOptions,
                    title: Self.autoEmptyTrashLabel(_:)
                )
            }
        }
    }

    private var globalCapControl: some View {
        // Stepper clamps to `in:` and rounds to `step:` natively — no manual
        // snapping like the slider needed. Writes still route through
        // `cacheUpdate(...)` so the cap persists and the scheduler restarts.
        let gbBinding = Binding<Int>(
            get: { Int(vm.cacheState.settings.globalCapBytes / 1_000_000_000) },
            set: { newGB in
                vm.cacheUpdate(
                    settings: vm.cacheState.settings.with(
                        globalCapBytes: newGB * 1_000_000_000
                    )
                )
            }
        )
        return HStack(spacing: 8) {
            Text("\(gbBinding.wrappedValue) GB")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 56, alignment: .trailing)
            Stepper(value: gbBinding, in: 10...200, step: 5) { EmptyView() }
                .labelsHidden()
        }
        .disabled(!vm.cacheState.settings.isEnabled)
    }

    // MARK: - Tracked folders section

    @ViewBuilder
    private var trackedFoldersRows: some View {
        // Helper-managed (catalog system) rows are pointless on ad-hoc
        // builds — they can never be sized or cleaned — so they're dropped
        // along with their auto-clean toggles.
        let rows = vm.cacheState.rows.filter {
            vm.privilegedHelper.isSupported || !$0.isHelperManaged
        }
        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
            if idx > 0 {
                SettingsSectionDivider()
            }
            trackedFolderRow(row)
        }
        SettingsSectionDivider()
        trackedFoldersFooter
    }

    private func trackedFolderRow(_ row: CachePathRow) -> some View {
        // Subtitle wraps vertically (no truncation) so long paths stay fully
        // readable — matches how Notifications / Awake render multi-line
        // subtitles. If row-height jitter shows up in dogfooding, we can
        // add a single-line subtitle variant to SettingsRow later.
        SettingsRow(
            title: row.displayName,
            subtitle: row.path.path,
            leadingBadges: badges(for: row)
        ) {
            HStack(spacing: 8) {
                Button {
                    vm.cacheRemoveRow(rowID: row.id)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from tracking")

                if row.isCleanable {
                    Toggle("Auto-clean \(row.displayName)", isOn: Binding(
                        get: { row.autoCleanEnabled },
                        set: { _ in vm.cacheToggleAuto(rowID: row.id) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }
    }

    private func badges(for row: CachePathRow) -> [SettingsRowBadge] {
        var out: [SettingsRowBadge] = []
        if row.risk == .caution {
            out.append(SettingsRowBadge(
                text: "caution",
                foreground: .orange,
                background: Color.orange.opacity(0.18)
            ))
        } else if row.risk == .risky {
            out.append(SettingsRowBadge(
                text: "risky",
                foreground: .red,
                background: Color.red.opacity(0.18)
            ))
        }
        if row.isCustom && !row.isSystem {
            out.append(SettingsRowBadge(
                text: "custom",
                foreground: .secondary,
                background: Color.secondary.opacity(0.15)
            ))
        }
        if !row.isSystem,
           CachePathRow.scopeCollisionNames(in: vm.cacheState.rows)
               .contains(row.displayName) {
            out.append(SettingsRowBadge(
                text: "user",
                foreground: .secondary,
                background: Color.secondary.opacity(0.15)
            ))
        }
        if row.isSystem {
            out.append(SettingsRowBadge(
                text: "system",
                foreground: .blue,
                background: Color.blue.opacity(0.15)
            ))
        }
        return out
    }

    private var trackedFoldersFooter: some View {
        // Inherits the default font (matches SettingsRow's 13pt feel) and
        // keeps the same 14×10 padding so the row sits flush with the
        // tracked-folder rows above. The hairline divider is rendered by
        // the caller (trackedFoldersRows) before this view.
        HStack(spacing: 10) {
            // No restore entry for helper-managed rows on ad-hoc builds —
            // restoring a row that can never be sized or cleaned is a dead end.
            let hidden = MenuBarViewModel.hiddenBuiltInRows(
                removed: vm.cacheState.removedDefaultPaths)
                .filter { vm.privilegedHelper.isSupported || !$0.isHelperManaged }
            if hidden.isEmpty {
                Button {
                    presentAddPathPanel()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add folder…")
                    }
                }
            } else {
                Menu {
                    Section("Restore removed") {
                        ForEach(hidden) { row in
                            Button(row.displayName) {
                                vm.cacheRestoreRemovedRow(path: row.path.path)
                            }
                        }
                    }
                    Divider()
                    Button("Choose a folder…") { presentAddPathPanel() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add folder…")
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer()
            Button("Reset to defaults") {
                vm.cacheResetDefaults()
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func presentAddPathPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Track"
        panel.message = "Choose a folder to track. Folders outside your home directory are tracked for size only — Kwota can't clean them."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser
        switch MenuBarViewModel.classifyAddPath(url, home: home) {
        case .custom:
            vm.cacheAddCustomPath(url: url)
        case .catalogRestore(let path):
            // The chosen path is a built-in catalog cache — restore the
            // cleanable catalog row instead of a tracking-only duplicate.
            vm.cacheRestoreRemovedRow(path: path)
        case .systemTracking:
            let alert = NSAlert()
            alert.messageText = "Track this folder for size only?"
            alert.informativeText = "“\(url.path)” is outside your home directory. Kwota will track its size but can't clean it — only built-in system caches can be cleaned."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Track")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            vm.cacheAddCustomPath(url: url, isSystem: true)
        case .unsupported(let reason):
            let alert = NSAlert()
            alert.messageText = "Can't track this folder"
            alert.informativeText = reason
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Privileged helper section

    @ViewBuilder
    private var privilegedHelperRows: some View {
        SettingsRow(
            title: "Status",
            subtitle: privilegedHelperSubtitle
        ) {
            switch vm.privilegedHelper.status {
            case .notInstalled:
                Button("Install helper") {
                    Task { await vm.privilegedHelper.install() }
                }
                .controlSize(.small)
            case .requiresApproval:
                Button("Open System Settings") {
                    openLoginItemsSettings()
                }
                .controlSize(.small)
            case .needsUpdate:
                Button("Update helper") {
                    Task { await vm.privilegedHelper.update() }
                }
                .controlSize(.small)
            case .enabled:
                Button("Remove helper") {
                    Task { await vm.privilegedHelper.uninstall() }
                }
                .controlSize(.small)
            }
        }
    }

    private var privilegedHelperSubtitle: String {
        switch vm.privilegedHelper.status {
        case .notInstalled:
            return "Not installed. System caches can't be cleaned until the helper is installed."
        case .requiresApproval:
            return "Registered — waiting for you to approve it in System Settings › General › Login Items."
        case .needsUpdate:
            return "Installed, but out of date. Update it so system-cache cleaning keeps working."
        case .enabled:
            return "Installed and ready. System caches are deleted permanently when cleaned."
        }
    }

    /// Deep-link to the Login Items pane where a `.requiresApproval` daemon
    /// is enabled.
    private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Helpers

    /// Day values for the Auto-empty Trash picker; 0 == off.
    fileprivate static let autoEmptyTrashOptions: [Int] = [0, 3, 7, 14, 30]

    /// Matches the inline labels the old `Picker` used.
    fileprivate static func autoEmptyTrashLabel(_ days: Int) -> String {
        days == 0 ? "Off" : "After \(days) day\(days == 1 ? "" : "s")"
    }
}
