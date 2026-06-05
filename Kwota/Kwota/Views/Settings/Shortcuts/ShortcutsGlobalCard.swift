//
//  ShortcutsGlobalCard.swift
//  Kwota
//

import SwiftUI

struct ShortcutsGlobalCard: View {
    let coordinator: ShortcutCoordinator
    let profileStore: ProfileStore

    @State private var definition: HotKeyDefinition?
    @State private var errorMessage: String?
    private let store = HotKeyStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Open popup")
                    .font(.headline)
                Spacer()
                HotKeyRecorderView(
                    definition: $definition,
                    onChange: handleChange
                )
            }

            Text("System-wide hotkey to open the Kwota popup. Some combinations may be claimed by other apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsCard()
        .onAppear {
            definition = store.definition(for: ShortcutNames.openPopup)
        }
    }

    private func handleChange() {
        guard let definition else {
            errorMessage = nil
            store.setDefinition(nil, for: ShortcutNames.openPopup)
            coordinator.reloadOpenPopup()
            return
        }

        let catalog = ShortcutCatalog.make(
            store: store,
            profiles: profileStore.profiles,
            excluding: .globalOpenPopup
        )

        let result = ShortcutValidator.validate(
            definition,
            in: ShortcutValidationContext(scope: .globalOpenPopup, catalog: catalog)
        )
        guard case .valid = result else {
            store.setDefinition(nil, for: ShortcutNames.openPopup)
            self.definition = nil
            errorMessage = result.errorMessage
            coordinator.reloadOpenPopup()
            return
        }

        errorMessage = nil
        for hiddenName in catalog.hiddenBindingsToPrune(matching: definition) {
            store.reset(hiddenName)
        }
        store.setDefinition(definition, for: ShortcutNames.openPopup)
        coordinator.reloadOpenPopup()
    }
}
