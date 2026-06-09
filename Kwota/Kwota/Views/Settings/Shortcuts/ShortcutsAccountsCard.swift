//
//  ShortcutsAccountsCard.swift
//  Kwota
//

import SwiftUI

struct ShortcutsAccountsCard: View {
    let vm: MenuBarViewModel

    @AppStorage(AppStorageKeys.isPrivacyMasked) private var isPrivacyMasked: Bool = false
    @State private var definitions: [UUID: HotKeyDefinition] = [:]
    @State private var errors: [UUID: String] = [:]
    @State private var previousLiveSet: Set<UUID> = []
    private let store = HotKeyStore()

    private var profileStore: ProfileStore { vm.profileStore }

    var body: some View {
        let live = liveness
        let liveProfiles = profileStore.profiles.filter {
            $0.kind == .auto && ProfileRowPresentation.isLive($0, liveness: live)
        }
        VStack(spacing: 0) {
            if profileStore.profiles.isEmpty {
                SettingsRow(
                    title: "No accounts yet",
                    subtitle: "Accounts appear here once you sign into a provider's CLI."
                ) { EmptyView() }
            } else if liveProfiles.isEmpty {
                SettingsRow(
                    title: "No live accounts",
                    subtitle: "Sign back into a provider's CLI to assign switch-account shortcuts."
                ) { EmptyView() }
            } else {
                ForEach(Array(liveProfiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 { SettingsSectionDivider() }
                    profileRow(profile)
                }
            }
        }
        .onAppear {
            reload()
            previousLiveSet = Set(liveProfiles.map(\.id))
        }
        .onChange(of: profileStore.profiles.map(\.id)) { _, _ in reload() }
        .onChange(of: liveness) { _, _ in handleLivenessChange() }
    }

    @ViewBuilder
    private func profileRow(_ profile: Profile) -> some View {
        SettingsRow(
            title: ProfileRowPresentation.displayName(profile, privacyMasked: isPrivacyMasked),
            subtitle: ProfileRowPresentation.planSubtitle(profile, privacyMasked: isPrivacyMasked),
            leadingBadges: ProfileRowPresentation.badges(
                for: profile,
                providerName: providerName(for: profile),
                isLive: true,
                includeOfflinePill: false
            )
        ) {
            HotKeyRecorderView(definition: binding(for: profile.id)) {
                handleChange(for: profile.id)
            }
        }
        if let error = errors[profile.id] {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }
    }

    private var liveness: ProfileLivenessContext {
        ProfileLivenessContext(
            claudeCLIEmail: vm.cliAccountWatcher.current?.email,
            codexCLIEmail: vm.codexAccountWatcher.current?.email,
            antigravityProcessAlive: vm.antigravityProcessWatcher.current != nil
        )
    }

    private func providerName(for profile: Profile) -> String {
        vm.registry.provider(for: profile.providerID)?.displayName
            ?? profile.providerID.rawValue.capitalized
    }

    private func binding(for id: UUID) -> Binding<HotKeyDefinition?> {
        Binding(
            get: { definitions[id] },
            set: { definitions[id] = $0 }
        )
    }

    private func handleChange(for id: UUID) {
        let key = ShortcutNames.switchProfile(id: id)

        guard let definition = definitions[id] else {
            errors[id] = nil
            store.setDefinition(nil, for: key)
            return
        }

        // Catalog uses live profiles only — offline accounts are hidden
        // from this card and their stored bindings stay dormant. If a
        // live profile takes a key currently bound to an offline account,
        // the collision is resolved when that account returns live (see
        // `handleLivenessChange`).
        let live = liveness
        let liveProfiles = profileStore.profiles.filter {
            $0.kind == .auto && ProfileRowPresentation.isLive($0, liveness: live)
        }
        let catalog = ShortcutCatalog.make(
            store: store,
            profiles: liveProfiles,
            excluding: .localSwitchProfile(profileID: id)
        )

        let result = ShortcutValidator.validate(
            definition,
            in: ShortcutValidationContext(
                scope: .localSwitchProfile(profileID: id),
                catalog: catalog
            )
        )
        guard case .valid = result else {
            store.setDefinition(nil, for: key)
            definitions[id] = nil
            errors[id] = result.errorMessage
            return
        }

        errors[id] = nil
        for hiddenName in catalog.hiddenBindingsToPrune(matching: definition) {
            store.reset(hiddenName)
        }
        store.setDefinition(definition, for: key)
    }

    /// When a previously-offline account returns live, restore its
    /// historical hotkey claim: clear any *other live* row that has been
    /// using the same key, and surface a per-row error so the user notices.
    private func handleLivenessChange() {
        let live = liveness
        let currentLiveSet: Set<UUID> = Set(
            profileStore.profiles
                .filter { $0.kind == .auto && ProfileRowPresentation.isLive($0, liveness: live) }
                .map(\.id)
        )
        let returners = currentLiveSet.subtracting(previousLiveSet)
        previousLiveSet = currentLiveSet
        guard !returners.isEmpty else { return }

        var liveBindings: [UUID: HotKeyDefinition] = [:]
        for id in currentLiveSet {
            if let def = store.definition(for: ShortcutNames.switchProfile(id: id)) {
                liveBindings[id] = def
            }
        }

        for returnerID in returners {
            let displaced = BindingReclaim.displacedByReturner(
                returnerID: returnerID, bindings: liveBindings
            )
            guard !displaced.isEmpty else { continue }
            let returnerName = displayName(for: returnerID)
            for displacedID in displaced {
                store.setDefinition(nil, for: ShortcutNames.switchProfile(id: displacedID))
                liveBindings[displacedID] = nil
                errors[displacedID] = "Reset because '\(returnerName)' reclaimed this shortcut on return."
            }
        }
        reload()
    }

    private func displayName(for id: UUID) -> String {
        guard let profile = profileStore.profiles.first(where: { $0.id == id }) else {
            return "another account"
        }
        return ProfileRowPresentation.displayName(profile, privacyMasked: isPrivacyMasked)
    }

    private func reload() {
        cleanupDeletedProfileShortcuts()
        var next: [UUID: HotKeyDefinition] = [:]
        for profile in profileStore.profiles {
            next[profile.id] = store.definition(for: ShortcutNames.switchProfile(id: profile.id))
        }
        definitions = next
        errors = errors.filter { next[$0.key] != nil }
    }

    private func cleanupDeletedProfileShortcuts() {
        let validNames = Set(profileStore.profiles.map { ShortcutNames.switchProfile(id: $0.id) })
        let storedNames = Set(store.names(withPrefix: "switchProfile."))

        for staleName in storedNames.subtracting(validNames) {
            store.reset(staleName)
        }
    }
}
