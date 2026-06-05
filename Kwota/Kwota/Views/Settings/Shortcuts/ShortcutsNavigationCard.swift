//
//  ShortcutsNavigationCard.swift
//  Kwota
//

import SwiftUI

struct ShortcutsNavigationCard: View {
    let profileStore: ProfileStore

    @State private var nextDefinition: HotKeyDefinition?
    @State private var previousDefinition: HotKeyDefinition?
    @State private var nextError: String?
    @State private var previousError: String?

    private let store = HotKeyStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            shortcutRow(
                title: "Next account",
                definition: $nextDefinition,
                errorMessage: nextError,
                onChange: { handleNavigationChange(scope: .localNextProfile) }
            )
            shortcutRow(
                title: "Previous account",
                definition: $previousDefinition,
                errorMessage: previousError,
                onChange: { handleNavigationChange(scope: .localPreviousProfile) }
            )
        }
        .settingsCard()
        .onAppear {
            nextDefinition = store.definition(for: ShortcutNames.nextProfile)
            previousDefinition = store.definition(for: ShortcutNames.previousProfile)
        }
    }

    @ViewBuilder
    private func shortcutRow(
        title: String,
        definition: Binding<HotKeyDefinition?>,
        errorMessage: String?,
        onChange: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.body)
                Spacer()
                HotKeyRecorderView(definition: definition, onChange: onChange)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func handleNavigationChange(scope: ShortcutScope) {
        let definition: HotKeyDefinition?
        let key: String

        switch scope {
        case .localNextProfile:
            definition = nextDefinition
            key = ShortcutNames.nextProfile
        case .localPreviousProfile:
            definition = previousDefinition
            key = ShortcutNames.previousProfile
        default:
            return
        }

        guard let definition else {
            setNavigationError(nil, for: scope)
            store.setDefinition(nil, for: key)
            return
        }

        let catalog = ShortcutCatalog.make(store: store, profiles: profileStore.profiles, excluding: scope)
        let result = ShortcutValidator.validate(
            definition,
            in: ShortcutValidationContext(scope: scope, catalog: catalog)
        )

        guard case .valid = result else {
            store.setDefinition(nil, for: key)
            setNavigationDefinition(nil, for: scope)
            setNavigationError(result.errorMessage, for: scope)
            return
        }

        setNavigationError(nil, for: scope)
        for hiddenName in catalog.hiddenBindingsToPrune(matching: definition) {
            store.reset(hiddenName)
        }
        store.setDefinition(definition, for: key)
    }

    private func setNavigationDefinition(_ definition: HotKeyDefinition?, for scope: ShortcutScope) {
        switch scope {
        case .localNextProfile:
            nextDefinition = definition
        case .localPreviousProfile:
            previousDefinition = definition
        default:
            break
        }
    }

    private func setNavigationError(_ message: String?, for scope: ShortcutScope) {
        switch scope {
        case .localNextProfile:
            nextError = message
        case .localPreviousProfile:
            previousError = message
        default:
            break
        }
    }
}
