//
//  ManageProfilesView.swift
//  Kwota
//

import SwiftUI

/// Settings ▸ Profiles. Two sections: Accounts / Archived.
/// The Accounts section lists every tracked auto profile across providers,
/// flagging the global-active one and dimming any not currently live.
/// Auto-detect drives profile lifecycle; users do not add or rename accounts here.
/// Tapping an Archived row opens a read-only history sheet.
struct ManageProfilesView: View {
    let vm: MenuBarViewModel

    @AppStorage(AppStorageKeys.isPrivacyMasked) private var isPrivacyMasked: Bool = false
    @State private var archivedExpanded: Bool = false
    @State private var selectedDetail: Profile?
    @State private var removeError: RemoveErrorAlert?

    private struct RemoveErrorAlert: Identifiable {
        let id = UUID()
        let profileName: String
        let message: String
    }

    private var archived: [Profile] {
        vm.profileStore.profiles.filter { $0.kind == .archived }
    }

    /// Liveness for a profile, mirroring the menu-bar switcher: a Claude/Codex
    /// profile is live when its email matches the CLI's current account; an
    /// Antigravity profile is live when the app process is running.
    private func isLive(_ profile: Profile) -> Bool {
        ProfileSwitcherCard.isLive(
            profile: profile,
            claudeCLIEmail: vm.cliAccountWatcher.current?.email,
            codexCLIEmail: vm.codexAccountWatcher.current?.email,
            antigravityProcessAlive: vm.antigravityProcessWatcher.current != nil
        )
    }

    private var displayedAccountRows: [AccountRow] {
        Self.accountRows(
            profiles: vm.profileStore.profiles,
            registry: vm.registry,
            activeID: vm.profileStore.activeProfileId,
            isLive: { isLive($0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader
                accountsSection
                if !archived.isEmpty { archivedSection }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .sheet(item: $selectedDetail) { p in
            ProfileDetailView(profile: p, vm: vm) {
                guard p.kind == .archived else { return }
                do {
                    try vm.profileStore.remove(id: p.id)
                } catch let error as ProfileStore.RemoveError {
                    switch error {
                    case .sideStateLingered(_, let keychainError, let directoryError):
                        let parts: [String] = [
                            keychainError.map { "credential: \($0.localizedDescription)" },
                            directoryError.map { "history: \($0.localizedDescription)" }
                        ].compactMap { $0 }
                        removeError = RemoveErrorAlert(
                            profileName: p.name,
                            message: parts.joined(separator: "; ")
                        )
                    }
                } catch {
                    removeError = RemoveErrorAlert(
                        profileName: p.name,
                        message: error.localizedDescription
                    )
                }
                selectedDetail = nil
            }
        }
        .alert(item: $removeError) { err in
            Alert(
                title: Text("Profile removed with residual data"),
                message: Text("Kwota removed '\(err.profileName)' from the list but some files could not be deleted: \(err.message). You may want to clean these manually."),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Header

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Kwota auto-detects the accounts you're signed into. Accounts appear here automatically.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                isPrivacyMasked.toggle()
            } label: {
                Label(
                    isPrivacyMasked ? "Show details" : "Mask details",
                    systemImage: isPrivacyMasked ? "eye.slash" : "eye"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(isPrivacyMasked ? "Show private info" : "Mask private info")
        }
    }

    // MARK: - Sections

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Accounts")
            let rows = displayedAccountRows
            if rows.isEmpty {
                NoActiveAccountEmptyView(
                    providerNames: vm.registry.all.map(\.displayName))
                    .background(rowBackground)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.profile.id) { idx, row in
                        profileRow(row.profile, isActive: row.isActive, isLive: row.isLive) {
                            selectedDetail = row.profile
                        }
                        if idx < rows.count - 1 {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(rowBackground)
            }
        }
    }

    private var archivedSection: some View {
        DisclosureGroup(isExpanded: $archivedExpanded) {
            VStack(spacing: 0) {
                ForEach(Array(archived.enumerated()), id: \.element.id) { idx, p in
                    archivedRow(p)
                    if idx < archived.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(rowBackground)
            .padding(.top, 8)
        } label: {
            // DisclosureGroup only toggles on a click of the chevron itself;
            // make the whole title row toggle too so tapping the label opens
            // it. contentShape widens the hit area past the text glyphs.
            sectionTitle("Archived accounts (\(archived.count))")
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation { archivedExpanded.toggle() }
                }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func profileRow(_ profile: Profile, isActive: Bool, isLive: Bool, tap: (() -> Void)?) -> some View {
        let content = HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(displayName(for: profile))
                        .font(.system(size: 14, weight: isActive ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isActive {
                        Text("Default")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                    } else if !isLive {
                        Text("Signed out")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.18), in: Capsule())
                    }
                }
                Text(metadataText(for: profile))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .opacity(isActive || isLive ? 1.0 : 0.55)

        if let tap {
            Button(action: tap) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func archivedRow(_ profile: Profile) -> some View {
        Button {
            selectedDetail = profile
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName(for: profile))
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Text(archivedMetadataText(for: profile))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private var rowBackground: some View {
        Color(.controlBackgroundColor).opacity(0.6)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func displayName(for profile: Profile) -> String {
        if let email = profile.email, !email.isEmpty {
            return isPrivacyMasked ? (profile.maskedEmail ?? email) : email
        }
        return profile.resolvedDisplayName
    }

    private func metadataText(for profile: Profile) -> String {
        let plan = isPrivacyMasked ? (profile.maskedPlan ?? "") : (profile.subscriptionPlan ?? "")
        let providerName = vm.registry.provider(for: profile.providerID)?.displayName ?? "Claude"
        var parts: [String] = [providerName]
        if !plan.isEmpty { parts.append(plan) }
        if let boundary = profile.ownershipBoundary {
            parts.append("tracking since \(boundary.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " • ")
    }

    private func archivedMetadataText(for profile: Profile) -> String {
        var parts: [String] = []
        if let plan = isPrivacyMasked ? profile.maskedPlan : profile.subscriptionPlan {
            parts.append(plan)
        }
        if let lastFetched = profile.lastFetchedAt {
            parts.append("last seen \(lastFetched.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("no fetch history")
        }
        return parts.joined(separator: " • ")
    }
}

extension ManageProfilesView {
    /// One row in the Accounts section.
    struct AccountRow: Equatable {
        let profile: Profile
        let isActive: Bool
        let isLive: Bool
    }

    /// Ordered rows for the Accounts section. Includes every `kind == .auto`
    /// profile whose provider is registered (live or not); `.archived` and
    /// unknown-provider profiles are dropped. The global-active profile floats
    /// to the top; the rest follow `registry.all` order, with a stable
    /// name tiebreak within a provider. `isLive` is injected so the view
    /// supplies the watcher-backed predicate and tests can pin it down.
    @MainActor
    static func accountRows(
        profiles: [Profile],
        registry: ProviderRegistry,
        activeID: UUID?,
        isLive: (Profile) -> Bool
    ) -> [AccountRow] {
        func providerOrder(_ id: ProviderID) -> Int? {
            registry.all.firstIndex { $0.id == id }
        }
        let autos = profiles.filter { $0.kind == .auto && providerOrder($0.providerID) != nil }
        let sorted = autos.sorted { a, b in
            let aActive = a.id == activeID
            let bActive = b.id == activeID
            if aActive != bActive { return aActive }
            let ao = providerOrder(a.providerID) ?? Int.max
            let bo = providerOrder(b.providerID) ?? Int.max
            if ao != bo { return ao < bo }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return sorted.map {
            AccountRow(profile: $0, isActive: $0.id == activeID, isLive: isLive($0))
        }
    }
}
