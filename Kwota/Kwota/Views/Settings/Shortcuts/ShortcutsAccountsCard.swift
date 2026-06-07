//
//  ShortcutsAccountsCard.swift
//  Kwota
//

import SwiftUI

struct ShortcutsAccountsCard: View {
    let profileStore: ProfileStore

    @State private var definitions: [UUID: HotKeyDefinition] = [:]
    @State private var errors: [UUID: String] = [:]
    private let store = HotKeyStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if profileStore.profiles.isEmpty {
                Text("Add an account in Accounts to assign a shortcut.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(profileStore.profiles, id: \.id) { profile in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .font(.body)
                            if let email = profile.email {
                                Text(email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        HotKeyRecorderView(definition: binding(for: profile.id)) {
                            handleChange(for: profile.id)
                        }
                    }
                    if let error = errors[profile.id] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if profile.id != profileStore.profiles.last?.id {
                        Divider()
                    }
                }
            }

            Text("Manage accounts in the Accounts tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .settingsCard()
        .onAppear { reload() }
        .onChange(of: profileStore.profiles.map(\.id)) { _, _ in reload() }
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

        let catalog = ShortcutCatalog.make(
            store: store,
            profiles: profileStore.profiles,
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
