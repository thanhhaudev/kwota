//
//  ProfileHistoryCard.swift
//  Kwota
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProfileHistoryCard: View {
    let vm: MenuBarViewModel

    @AppStorage(AppStorageKeys.isPrivacyMasked) private var isPrivacyMasked: Bool = false
    @State private var rowEntryCounts: [UUID: Int] = [:]
    @State private var clearingTarget: Profile?
    @State private var showClearAlert: Bool = false
    @State private var clearError: ClearError?

    private struct ClearError: Identifiable {
        let id = UUID()
        let profileName: String
        let message: String
    }

    var body: some View {
        let ordered = orderedProfiles
        VStack(spacing: 0) {
            if ordered.isEmpty {
                SettingsRow(title: "No accounts yet",
                            subtitle: "Accounts appear here once you sign into a provider's CLI.") { EmptyView() }
            } else {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 { SettingsSectionDivider() }
                    profileRow(profile)
                }
            }
        }
        // Counts go stale fast: background refreshes append history entries
        // to disk without updating any vm-published property the row already
        // observes. Two triggers handle that:
        //  - `.task` polls every 5s while the tab is visible — covers
        //    non-active profiles written by ProfileSwitcherFetchCoordinator.
        //  - `.onChange(of: vm.lastFetchedAt)` re-reads instantly when the
        //    active profile lands a fetch, so the row updates in real time.
        // Both are visibility-gated (task cancels, onChange only fires while
        // the view is in the hierarchy) so idle Settings windows don't burn
        // cycles.
        .task {
            await refreshCounts()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await refreshCounts()
            }
        }
        .onChange(of: vm.lastFetchedAt) { _, _ in
            Task { await refreshCounts() }
        }
        .alert(
            "Clear usage history?",
            isPresented: $showClearAlert,
            presenting: clearingTarget
        ) { profile in
            Button("Clear", role: .destructive) {
                clearHistory(for: profile)
                clearingTarget = nil
            }
            Button("Cancel", role: .cancel) {
                clearingTarget = nil
            }
        } message: { profile in
            Text("This deletes the on-disk history file for '\(profile.name)'. The action cannot be undone.")
        }
        .alert(item: $clearError) { err in
            Alert(
                title: Text("Could not clear history"),
                message: Text("Removing the history file for '\(err.profileName)' failed: \(err.message)"),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func profileRow(_ profile: Profile) -> some View {
        let entryCount = rowEntryCounts[profile.id] ?? 0
        return SettingsRow(
            title: displayName(for: profile),
            subtitle: subtitle(for: profile, entries: entryCount),
            leadingBadges: badges(for: profile)
        ) {
            Menu {
                menuContent(for: profile, entryCount: entryCount)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("History actions for \(profile.name)")
        }
        .contextMenu { menuContent(for: profile, entryCount: entryCount) }
    }

    @ViewBuilder
    private func menuContent(for profile: Profile, entryCount: Int) -> some View {
        Button("Export…") { exportHistory(for: profile) }
            .disabled(entryCount == 0)
        Divider()
        Button("Clear", role: .destructive) {
            clearingTarget = profile
            showClearAlert = true
        }
    }

    private func displayName(for profile: Profile) -> String {
        ProfileRowPresentation.displayName(profile, privacyMasked: isPrivacyMasked)
    }

    private func subtitle(for profile: Profile, entries: Int) -> String {
        let countLabel = "\(entries) \(entries == 1 ? "entry" : "entries")"
        if let plan = ProfileRowPresentation.planSubtitle(profile, privacyMasked: isPrivacyMasked) {
            return "\(plan) · \(countLabel)"
        }
        return countLabel
    }

    private func badges(for profile: Profile) -> [SettingsRowBadge] {
        let providerName = vm.registry.provider(for: profile.providerID)?.displayName
            ?? profile.providerID.rawValue.capitalized
        return ProfileRowPresentation.badges(
            for: profile,
            providerName: providerName,
            isLive: isLive(profile)
        )
    }

    private var liveness: ProfileLivenessContext {
        ProfileLivenessContext(
            claudeCLIEmail: vm.cliAccountWatcher.current?.email,
            codexCLIEmail: vm.codexAccountWatcher.current?.email,
            antigravityProcessAlive: vm.antigravityProcessWatcher.current != nil
        )
    }

    private func isLive(_ profile: Profile) -> Bool {
        ProfileRowPresentation.isLive(profile, liveness: liveness)
    }

    private var orderedProfiles: [Profile] {
        ProfileRowPresentation.ordered(vm.profileStore.profiles, liveness: liveness)
    }

    @MainActor
    private func refreshCounts() async {
        var counts: [UUID: Int] = [:]
        for p in vm.profileStore.profiles {
            counts[p.id] = await loadCount(profileId: p.id)
        }
        rowEntryCounts = counts
    }

    private func loadCount(profileId: UUID) async -> Int {
        await OffMain.run {
            let url = AppPaths.usageHistoryFile(id: profileId)
            guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
            guard let data = try? Data(contentsOf: url) else { return 0 }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .secondsSince1970
            return (try? dec.decode([UsageHistoryEntry].self, from: data).count) ?? 0
        }
    }

    private func clearHistory(for profile: Profile) {
        let url = AppPaths.usageHistoryFile(id: profile.id)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            rowEntryCounts[profile.id] = 0
            if profile.id == vm.profileStore.activeProfileId {
                vm.reloadHistoryStores()
            }
        } catch {
            AppLog.shared.log(
                "ProfileHistoryCard.clearHistory failed for profile=\(profile.id): \(error)",
                level: .error
            )
            clearError = ClearError(
                profileName: profile.name,
                message: error.localizedDescription
            )
            // Recount from disk in case removeItem partially succeeded so
            // the row matches reality.
            Task { @MainActor in
                rowEntryCounts[profile.id] = await loadCount(profileId: profile.id)
            }
        }
    }

    private func exportHistory(for profile: Profile) {
        let url = AppPaths.usageHistoryFile(id: profile.id)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let entries = try? dec.decode([UsageHistoryEntry].self, from: data) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText, .json]
        panel.nameFieldStringValue = "kwota-\(profile.name).json"
        panel.canCreateDirectories = true
        panel.title = "Export Usage History"
        guard panel.runModal() == .OK, let saveURL = panel.url else { return }

        do {
            if saveURL.pathExtension.lowercased() == "csv" {
                let csv = HistoryExporter.csv(entries)
                try csv.data(using: .utf8)?.write(to: saveURL)
            } else {
                let json = try HistoryExporter.json(entries)
                try json.write(to: saveURL)
            }
        } catch {
            AppLog.shared.log("ProfileHistoryCard export failed: \(error)", level: .warn)
        }
    }
}
