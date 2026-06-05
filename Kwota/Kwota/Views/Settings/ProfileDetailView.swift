//
//  ProfileDetailView.swift
//  Kwota
//

import AppKit
import SwiftUI

/// Unified detail sheet for both active and archived profiles. Reached
/// from `ManageProfilesView` by tapping any row. Renders account /
/// subscription / organization metadata sourced from
/// `/api/oauth/profile` (cached on `Profile`), an Identifiers
/// disclosure block, and conditional sections:
///   - Active profile → Refresh button + banner
///   - Archived profile → Usage history + Delete button
struct ProfileDetailView: View {
    let profile: Profile
    let vm: MenuBarViewModel
    /// Called when the user confirms delete (archived only). Parent
    /// (`ManageProfilesView`) is responsible for the actual store mutation
    /// + alert handling.
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKeys.isPrivacyMasked) private var isPrivacyMasked: Bool = false
    @State private var historyExpanded: Bool = false
    @State private var identifiersExpanded: Bool = false
    @State private var history: [UsageHistoryEntry] = []
    @State private var historyLoadError: String?
    @State private var refreshState: RefreshState = .idle

    private enum RefreshState: Equatable {
        case idle
        case loading
        case banner(BannerKind, message: String)
    }
    private enum BannerKind: Equatable { case success, warning, error }

    /// Always read the latest profile from the store so background
    /// probes that complete while the sheet is open re-render the body.
    /// Falls back to the snapshot passed in if the profile vanishes.
    private var liveProfile: Profile {
        vm.profileStore.profiles.first(where: { $0.id == profile.id }) ?? profile
    }
    private var isArchived: Bool { liveProfile.kind == .archived }

    /// The provider backing this profile, looked up from the registry.
    private var provider: (any AccountProvider)? {
        vm.registry.provider(for: liveProfile.providerID)
    }
    /// Detail fields applicable to this profile's provider. Falls back to the
    /// full set for an unknown provider not present in the registry.
    private var detailFields: Set<ProfileDetailField> {
        provider?.supportedProfileDetailFields ?? Set(ProfileDetailField.allCases)
    }
    private var visibility: ProfileDetailVisibility {
        ProfileDetailVisibility(fields: detailFields)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if case .banner(let kind, let msg) = refreshState {
                    banner(kind: kind, message: msg)
                }
                accountSection
                subscriptionSection
                organizationSection
                identifiersDisclosure
                if isArchived {
                    historyDisclosure
                    HStack {
                        Spacer()
                        deleteButton
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 480, minHeight: 420)
        .task { if isArchived { await loadHistory() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ProviderIconView(assetName: provider?.iconAssetName ?? "Mascot", size: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayedName)
                    .font(.title3.bold())
                    .lineLimit(1).truncationMode(.middle)
                if let email = displayedEmail {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    if let provider {
                        provider.planBadgeView(profile: liveProfile)
                    }
                    badge(
                        text: isArchived ? "Archived" : "Default",
                        foreground: isArchived ? .secondary : .white,
                        background: isArchived
                            ? Color.secondary.opacity(0.18)
                            : Color.accentColor
                    )
                }
            }
            Spacer()
            if !isArchived { refreshButton }
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await runRefresh() }
        } label: {
            if refreshState == .loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
            }
        }
        .buttonStyle(.borderless)
        .disabled(refreshState == .loading)
        .help("Refresh profile from \(provider?.displayName ?? "provider")")
    }

    private func badge(text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(background))
            .foregroundStyle(foreground)
    }

    // MARK: - Banner

    private func banner(kind: BannerKind, message: String) -> some View {
        let tint: Color
        let icon: String
        switch kind {
        case .success: tint = .green;  icon = "checkmark.circle.fill"
        case .warning: tint = .orange; icon = "exclamationmark.triangle.fill"
        case .error:   tint = .red;    icon = "xmark.octagon.fill"
        }
        return HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(message).font(.subheadline)
            Spacer()
            if kind != .success {
                Button {
                    refreshState = .idle
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Sections

    private var accountSection: some View {
        section(title: "Account") {
            // `displayName` is only populated by Claude's OAuth profile fetch;
            // Codex/Antigravity (and not-yet-fetched profiles) leave it nil.
            // Fall back to `name` the same way the header's `displayedName`
            // does so this always-shown row never collapses to a placeholder.
            kvRow("Display name", displayedName)
            if visibility.showsEmail {
                kvRow("Email", displayedEmail ?? ProfileDetailFormatter.placeholder)
            }
            if visibility.showsAccountCreated {
                kvRow("Account created",
                      liveProfile.accountCreatedAt.map { Self.dateFormatter.string(from: $0) }
                      ?? ProfileDetailFormatter.placeholder)
            }
        }
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        if visibility.showsSubscriptionSection {
            section(title: "Subscription") {
                if visibility.showsPlan {
                    kvRow("Plan", value(liveProfile.subscriptionPlan))
                }
                if visibility.showsSubscriptionStatus {
                    kvRow("Status", ProfileDetailFormatter.subscriptionStatus(liveProfile.subscriptionStatus))
                }
                if visibility.showsSubscriptionStarted {
                    kvRow("Started",
                          liveProfile.subscriptionCreatedAt.map { Self.dateFormatter.string(from: $0) }
                          ?? ProfileDetailFormatter.placeholder)
                }
                if visibility.showsBilling {
                    kvRow("Billing", ProfileDetailFormatter.billingType(liveProfile.billingType))
                }
                if visibility.showsExtraUsage {
                    kvRow("Extra usage", ProfileDetailFormatter.hasExtraUsage(liveProfile.hasExtraUsageEnabled))
                }
            }
        }
    }

    @ViewBuilder
    private var organizationSection: some View {
        if visibility.showsOrganizationSection {
            section(title: "Organization") {
                kvRow("Name", displayedOrganizationName)
            }
        }
    }

    private var identifiersDisclosure: some View {
        DisclosureGroup(isExpanded: $identifiersExpanded) {
            VStack(spacing: 0) {
                if visibility.showsAccountUUID {
                    copyableRow("Account UUID", liveProfile.accountUuid)
                    Divider().padding(.leading, 14)
                }
                if visibility.showsOrgUUID {
                    copyableRow("Org UUID", liveProfile.organizationId)
                    Divider().padding(.leading, 14)
                }
                copyableRow("Profile ID", liveProfile.id.uuidString)
            }
            .background(rowBackground)
        } label: {
            sectionTitle("Identifiers")
        }
    }

    private var historyDisclosure: some View {
        DisclosureGroup(isExpanded: $historyExpanded) {
            historyContent
        } label: {
            sectionTitle("Usage history (\(history.count))")
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if let err = historyLoadError {
            Text(err).font(.subheadline).foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else if history.isEmpty {
            Text("No saved usage history for this account.")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(history) { entry in
                    HStack {
                        Text(entry.at.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let pct = entry.sevenDay {
                            Text("\(Int(pct * 100))%")
                                .font(.system(size: 12))
                        } else if let pct = entry.fiveHour {
                            Text("\(Int(pct * 100))%")
                                .font(.system(size: 12))
                        } else {
                            Text(ProfileDetailFormatter.placeholder)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            onDelete()
            dismiss()
        } label: {
            Label("Delete profile", systemImage: "trash")
        }
    }

    // MARK: - Row helpers

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            VStack(spacing: 0) {
                content()
            }
            .background(rowBackground)
        }
    }

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

    private func kvRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func copyableRow(_ key: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(maskedIdentifier(value))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            if let value, !value.isEmpty {
                Button {
                    // Copy the masked form when privacy masking is on, so
                    // raw identifiers never reach the system clipboard
                    // unless the user has explicitly unmasked the sheet.
                    // Codex round 5 flagged the raw-copy bypass.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(maskedIdentifier(value), forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Display computed properties

    /// Header title. Prefers `displayName` (user-set, e.g. "Hau") over
    /// `Profile.name` (row label, may be the raw email for auto-created
    /// profiles with no display name). When privacy masking is on AND the
    /// resolved string contains "@", we mask the email portion through the
    /// same helper used for organization names — keeping the local-part
    /// first character + "••••" + domain. Returning the raw email here
    /// would defeat the purpose of the page-header mask toggle.
    private var displayedName: String {
        let raw = liveProfile.resolvedDisplayName
        return isPrivacyMasked ? ProfileDetailFormatter.organizationNameMasked(raw) : raw
    }

    private var displayedEmail: String? {
        guard let email = liveProfile.email, !email.isEmpty else { return nil }
        return isPrivacyMasked ? (liveProfile.maskedEmail ?? email) : email
    }

    private var displayedOrganizationName: String {
        guard let raw = liveProfile.organizationName, !raw.isEmpty else {
            return ProfileDetailFormatter.placeholder
        }
        return isPrivacyMasked ? ProfileDetailFormatter.organizationNameMasked(raw) : raw
    }

    private func value(_ s: String?) -> String {
        s.flatMap { $0.isEmpty ? nil : $0 } ?? ProfileDetailFormatter.placeholder
    }

    private func maskedIdentifier(_ raw: String?) -> String {
        isPrivacyMasked ? ProfileDetailFormatter.uuidMasked(raw) : (raw ?? ProfileDetailFormatter.placeholder)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    // MARK: - Refresh action

    private func runRefresh() async {
        refreshState = .loading
        let result = await vm.refreshProfileMetadata(for: profile.id)
        switch result {
        case .updated:
            refreshState = .banner(.success, message: "Profile updated")
            scheduleSuccessDismiss()
        case .noChange:
            refreshState = .banner(.success, message: "Profile is up to date")
            scheduleSuccessDismiss()
        case .unauthorized:
            refreshState = .banner(.error,
                message: provider?.reauthInstruction
                    ?? "Authorization expired. Sign in again.")
        case .rateLimited(let retry):
            if let retry, retry > 0 {
                refreshState = .banner(.warning,
                    message: "Rate limited. Try again in \(Int(retry)) seconds.")
            } else {
                refreshState = .banner(.warning, message: "Rate limited. Try again later.")
            }
        case .offline:
            refreshState = .banner(.warning, message: "No internet connection.")
        case .otherError(let msg):
            refreshState = .banner(.error, message: msg)
        }
    }

    private func scheduleSuccessDismiss() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if case .banner(.success, _) = refreshState {
                refreshState = .idle
            }
        }
    }

    // MARK: - History loading

    @MainActor
    private func loadHistory() async {
        let store = UsageHistoryStore(
            historyFile: AppPaths.usageHistoryFile(id: profile.id)
        )
        do {
            history = try store.load()
        } catch {
            historyLoadError = "Could not load history: \(error.localizedDescription)"
        }
    }
}
