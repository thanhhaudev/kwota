//
//  ShortcutValidation.swift
//  Kwota
//

import AppKit
import Foundation

enum ShortcutScope: Equatable {
    case globalOpenPopup
    case localNextProfile
    case localPreviousProfile
    case localSwitchProfile(profileID: UUID)
    case localNextTab
    case localPreviousTab
    case localSwitchTab(MenuBarViewModel.Tab)
}

enum ShortcutValidationResult: Equatable {
    case valid
    case missingModifier
    case invalidBareKeyForArrowOnlyNavigation
    case reservedBySystem(label: String)
    case conflictsWithShortcut(label: String)

    var errorMessage: String? {
        switch self {
        case .valid:
            nil
        case .missingModifier:
            "Shortcut must include a modifier."
        case .invalidBareKeyForArrowOnlyNavigation:
            "Only arrow keys can be used without modifiers."
        case .reservedBySystem:
            "Reserved by macOS."
        case .conflictsWithShortcut(let label):
            "Shortcut already used by \(label)."
        }
    }
}

struct ShortcutCatalogEntry: Equatable {
    let definition: HotKeyDefinition
    let scope: ShortcutScope
    let label: String
}

struct ShortcutValidationContext {
    let scope: ShortcutScope
    let catalog: ShortcutCatalog
}

struct HiddenShortcutBinding: Equatable {
    let definition: HotKeyDefinition
    let names: [String]
}

struct ShortcutCatalog: Equatable {
    let entries: [ShortcutCatalogEntry]
    let hiddenBindings: [HiddenShortcutBinding]

    init(
        entries: [ShortcutCatalogEntry],
        hiddenBindings: [HiddenShortcutBinding] = []
    ) {
        self.entries = entries
        self.hiddenBindings = hiddenBindings
    }

    func entry(matching definition: HotKeyDefinition) -> ShortcutCatalogEntry? {
        entries.first { $0.definition == definition }
    }

    func hiddenBindingsToPrune(matching definition: HotKeyDefinition) -> [String] {
        hiddenBindings.first(where: { $0.definition == definition })?.names ?? []
    }

    static func make(
        store: HotKeyStore,
        profiles: [Profile],
        tabVisibility: PopoverTabVisibility = PopoverTabVisibility(),
        excluding excludedScope: ShortcutScope? = nil
    ) -> ShortcutCatalog {
        var entries: [ShortcutCatalogEntry] = []
        var hiddenBindingsByDefinition: [HotKeyDefinition: [String]] = [:]

        func append(_ scope: ShortcutScope, name: String, label: String) {
            guard excludedScope != scope,
                  let definition = store.definition(for: name) else {
                return
            }
            entries.append(ShortcutCatalogEntry(definition: definition, scope: scope, label: label))
        }

        append(.globalOpenPopup, name: ShortcutNames.openPopup, label: "Open popup")
        append(.localNextProfile, name: ShortcutNames.nextProfile, label: "Next account")
        append(.localPreviousProfile, name: ShortcutNames.previousProfile, label: "Previous account")
        append(.localNextTab, name: ShortcutNames.nextTab, label: "Next tab")
        append(.localPreviousTab, name: ShortcutNames.previousTab, label: "Previous tab")

        for profile in profiles {
            append(
                .localSwitchProfile(profileID: profile.id),
                name: ShortcutNames.switchProfile(id: profile.id),
                label: "Switch to \(profile.name)"
            )
        }

        for tab in MenuBarViewModel.Tab.allCases {
            let name = ShortcutNames.switchTab(tab)
            guard excludedScope != .localSwitchTab(tab),
                  let definition = store.definition(for: name) else {
                continue
            }

            if tabVisibility.isVisible(tab) {
                entries.append(
                    ShortcutCatalogEntry(
                        definition: definition,
                        scope: .localSwitchTab(tab),
                        label: "Switch to \(tab.label)"
                    )
                )
            } else {
                hiddenBindingsByDefinition[definition, default: []].append(name)
            }
        }

        return ShortcutCatalog(
            entries: entries,
            hiddenBindings: hiddenBindingsByDefinition.map { HiddenShortcutBinding(definition: $0.key, names: $0.value) }
        )
    }
}

enum ShortcutValidator {
    static func validate(
        _ definition: HotKeyDefinition,
        in context: ShortcutValidationContext
    ) -> ShortcutValidationResult {
        switch context.scope {
        case .localNextProfile, .localPreviousProfile, .localNextTab, .localPreviousTab:
            if definition.nsModifiers.isEmpty && !allowedBareArrowKeyCodes.contains(definition.keyCode) {
                return .invalidBareKeyForArrowOnlyNavigation
            }
        case .globalOpenPopup, .localSwitchProfile, .localSwitchTab:
            if definition.nsModifiers.isEmpty {
                return .missingModifier
            }
        }
        if let reserved = reservedSystemShortcut(matching: definition) {
            return .reservedBySystem(label: reserved)
        }
        if let conflict = context.catalog.entry(matching: definition) {
            return .conflictsWithShortcut(label: conflict.label)
        }
        return .valid
    }

    private static let allowedBareArrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]

    private static func reservedSystemShortcut(matching definition: HotKeyDefinition) -> String? {
        for shortcut in reservedSystemShortcuts where shortcut.definition == definition {
            return shortcut.label
        }
        return nil
    }

    private static let reservedSystemShortcuts: [ShortcutCatalogEntry] = [
        ShortcutCatalogEntry(
            definition: HotKeyDefinition(keyCode: 12, rawModifiers: NSEvent.ModifierFlags.command.rawValue),
            scope: .globalOpenPopup,
            label: "Quit"
        ),
        ShortcutCatalogEntry(
            definition: HotKeyDefinition(keyCode: 13, rawModifiers: NSEvent.ModifierFlags.command.rawValue),
            scope: .globalOpenPopup,
            label: "Close Window"
        ),
        ShortcutCatalogEntry(
            definition: HotKeyDefinition(keyCode: 43, rawModifiers: NSEvent.ModifierFlags.command.rawValue),
            scope: .globalOpenPopup,
            label: "Settings"
        ),
        ShortcutCatalogEntry(
            definition: HotKeyDefinition(keyCode: 4, rawModifiers: NSEvent.ModifierFlags.command.rawValue),
            scope: .globalOpenPopup,
            label: "Hide"
        ),
        ShortcutCatalogEntry(
            definition: HotKeyDefinition(keyCode: 46, rawModifiers: NSEvent.ModifierFlags.command.rawValue),
            scope: .globalOpenPopup,
            label: "Minimize"
        ),
    ]
}
