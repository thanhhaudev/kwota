//
//  ShortcutsTabsCard.swift
//  Kwota
//

import SwiftUI

struct ShortcutsTabsCard: View {
    @AppStorage(AppStorageKeys.displayPopoverShowAwake) private var showAwake: Bool = true
    @AppStorage(AppStorageKeys.displayPopoverShowCache) private var showCache: Bool = true

    @State private var nextDefinition: HotKeyDefinition?
    @State private var previousDefinition: HotKeyDefinition?
    @State private var nextError: String?
    @State private var previousError: String?
    @State private var tabDefinitions: [MenuBarViewModel.Tab: HotKeyDefinition] = [:]
    @State private var tabErrors: [MenuBarViewModel.Tab: String] = [:]

    private let store = HotKeyStore()

    private var tabVisibility: PopoverTabVisibility {
        PopoverTabVisibility()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                shortcutRow(
                    title: "Next tab",
                    definition: $nextDefinition,
                    errorMessage: nextError,
                    onChange: { handleNavigationChange(scope: .localNextTab) }
                )
                shortcutRow(
                    title: "Previous tab",
                    definition: $previousDefinition,
                    errorMessage: previousError,
                    onChange: { handleNavigationChange(scope: .localPreviousTab) }
                )
            }

            Divider()

            Text("Direct tab shortcuts")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(MenuBarViewModel.Tab.allCases) { tab in
                    shortcutRow(
                        title: tab.label,
                        definition: binding(for: tab),
                        errorMessage: tabErrors[tab],
                        isEnabled: tabVisibility.isVisible(tab),
                        disabledMessage: tab == .usage || tabVisibility.isVisible(tab)
                            ? nil
                            : "Enable this tab in Display > Popover tabs to edit its shortcut.",
                        onChange: { handleDirectTabChange(for: tab) }
                    )
                }
            }
        }
        .settingsCard()
        .onAppear(perform: reload)
        .onChange(of: showAwake) { _, _ in reload() }
        .onChange(of: showCache) { _, _ in reload() }
    }

    private func binding(for tab: MenuBarViewModel.Tab) -> Binding<HotKeyDefinition?> {
        Binding(
            get: { tabDefinitions[tab] },
            set: { tabDefinitions[tab] = $0 }
        )
    }

    @ViewBuilder
    private func shortcutRow(
        title: String,
        definition: Binding<HotKeyDefinition?>,
        errorMessage: String?,
        isEnabled: Bool = true,
        disabledMessage: String? = nil,
        onChange: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.body)
                Spacer()
                HotKeyRecorderView(definition: definition, onChange: onChange)
                    .disabled(!isEnabled)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let disabledMessage, !isEnabled {
                Text(disabledMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func handleNavigationChange(scope: ShortcutScope) {
        let definition: HotKeyDefinition?
        let key: String

        switch scope {
        case .localNextTab:
            definition = nextDefinition
            key = ShortcutNames.nextTab
        case .localPreviousTab:
            definition = previousDefinition
            key = ShortcutNames.previousTab
        default:
            return
        }

        guard let definition else {
            setNavigationError(nil, for: scope)
            store.setDefinition(nil, for: key)
            reload()
            return
        }

        let catalog = ShortcutCatalog.make(
            store: store,
            profiles: [],
            tabVisibility: tabVisibility,
            excluding: scope
        )
        let result = ShortcutValidator.validate(
            definition,
            in: ShortcutValidationContext(scope: scope, catalog: catalog)
        )

        guard case .valid = result else {
            store.setDefinition(nil, for: key)
            setNavigationDefinition(nil, for: scope)
            setNavigationError(result.errorMessage, for: scope)
            reload()
            return
        }

        for hiddenName in catalog.hiddenBindingsToPrune(matching: definition) {
            store.reset(hiddenName)
        }
        setNavigationError(nil, for: scope)
        store.setDefinition(definition, for: key)
        reload()
    }

    private func handleDirectTabChange(for tab: MenuBarViewModel.Tab) {
        let key = ShortcutNames.switchTab(tab)

        guard let definition = tabDefinitions[tab] else {
            tabErrors[tab] = nil
            store.setDefinition(nil, for: key)
            reload()
            return
        }

        let scope = ShortcutScope.localSwitchTab(tab)
        let catalog = ShortcutCatalog.make(
            store: store,
            profiles: [],
            tabVisibility: tabVisibility,
            excluding: scope
        )
        let result = ShortcutValidator.validate(
            definition,
            in: ShortcutValidationContext(scope: scope, catalog: catalog)
        )

        guard case .valid = result else {
            store.setDefinition(nil, for: key)
            tabDefinitions[tab] = nil
            tabErrors[tab] = result.errorMessage
            reload()
            return
        }

        for hiddenName in catalog.hiddenBindingsToPrune(matching: definition) {
            store.reset(hiddenName)
        }
        tabErrors[tab] = nil
        store.setDefinition(definition, for: key)
        reload()
    }

    private func setNavigationDefinition(_ definition: HotKeyDefinition?, for scope: ShortcutScope) {
        switch scope {
        case .localNextTab:
            nextDefinition = definition
        case .localPreviousTab:
            previousDefinition = definition
        default:
            break
        }
    }

    private func setNavigationError(_ message: String?, for scope: ShortcutScope) {
        switch scope {
        case .localNextTab:
            nextError = message
        case .localPreviousTab:
            previousError = message
        default:
            break
        }
    }

    private func reload() {
        nextDefinition = store.definition(for: ShortcutNames.nextTab)
        previousDefinition = store.definition(for: ShortcutNames.previousTab)

        var nextTabDefinitions: [MenuBarViewModel.Tab: HotKeyDefinition] = [:]
        for tab in MenuBarViewModel.Tab.allCases {
            nextTabDefinitions[tab] = store.definition(for: ShortcutNames.switchTab(tab))
        }
        tabDefinitions = nextTabDefinitions
        tabErrors = tabErrors.filter { nextTabDefinitions[$0.key] != nil }
    }
}
