//
//  ProfileHistoryCard.swift
//  Kwota
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProfileHistoryCard: View {
    let vm: MenuBarViewModel

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
        VStack(spacing: 0) {
            if vm.profileStore.profiles.isEmpty {
                SettingsRow(title: "No profiles yet",
                            subtitle: "Add a profile to track usage history.") { EmptyView() }
            } else {
                ForEach(vm.profileStore.profiles.enumerated(), id: \.element.id) { index, profile in
                    if index > 0 { SettingsSectionDivider() }
                    profileRow(profile)
                }
            }
        }
        .task(id: vm.profileStore.profiles.map(\.id)) { await refreshCounts() }
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
        SettingsRow(title: profile.name,
                    subtitle: "\(rowEntryCounts[profile.id] ?? 0) entries") {
            HStack(spacing: 6) {
                Button("Clear") {
                    clearingTarget = profile
                    showClearAlert = true
                }
                .buttonStyle(.bordered).controlSize(.small)
                Button("Export…") { exportHistory(for: profile) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled((rowEntryCounts[profile.id] ?? 0) == 0)
            }
        }
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
        await Task.detached(priority: .utility) {
            let url = AppPaths.usageHistoryFile(id: profileId)
            guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
            guard let data = try? Data(contentsOf: url) else { return 0 }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .secondsSince1970
            return (try? dec.decode([UsageHistoryEntry].self, from: data).count) ?? 0
        }.value
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
