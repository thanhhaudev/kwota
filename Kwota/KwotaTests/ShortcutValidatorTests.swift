import XCTest
import AppKit
@testable import Kwota

final class ShortcutValidatorTests: XCTestCase {
    private func def(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> HotKeyDefinition {
        HotKeyDefinition(keyCode: keyCode, rawModifiers: modifiers.rawValue)
    }

    func test_missingModifier_isRejected() {
        let candidate = def(18, [])

        XCTAssertEqual(
            ShortcutValidator.validate(
                candidate,
                in: ShortcutValidationContext(
                    scope: .globalOpenPopup,
                    catalog: ShortcutCatalog(entries: [])
                )
            ),
            .missingModifier
        )
    }

    func test_accountNavigation_acceptsBareUpArrow() {
        let candidate = def(126, [])

        XCTAssertEqual(
            ShortcutValidator.validate(
                candidate,
                in: ShortcutValidationContext(
                    scope: .localNextProfile,
                    catalog: ShortcutCatalog(entries: [])
                )
            ),
            .valid
        )
    }

    func test_accountNavigation_rejectsBareLetter() {
        let candidate = def(0, [])

        XCTAssertEqual(
            ShortcutValidator.validate(
                candidate,
                in: ShortcutValidationContext(
                    scope: .localNextProfile,
                    catalog: ShortcutCatalog(entries: [])
                )
            ),
            .invalidBareKeyForArrowOnlyNavigation
        )
    }

    func test_directTabShortcut_requiresModifier() {
        let candidate = def(18, [])

        XCTAssertEqual(
            ShortcutValidator.validate(
                candidate,
                in: ShortcutValidationContext(
                    scope: .localSwitchTab(.usage),
                    catalog: ShortcutCatalog(entries: [])
                )
            ),
            .missingModifier
        )
    }

    func test_reservedMacOSShortcut_isRejected() {
        let candidate = def(12, [.command])

        XCTAssertEqual(
            ShortcutValidator.validate(
                candidate,
                in: ShortcutValidationContext(
                    scope: .globalOpenPopup,
                    catalog: ShortcutCatalog(entries: [])
                )
            ),
            .reservedBySystem(label: "Quit")
        )
    }

    func test_internalConflict_isRejectedWithExistingLabel() {
        let candidate = def(40, [.command])
        let catalog = ShortcutCatalog(entries: [
            ShortcutCatalogEntry(
                definition: candidate,
                scope: .globalOpenPopup,
                label: "Open popup"
            ),
        ])

        XCTAssertEqual(
            ShortcutValidator.validate(
                candidate,
                in: ShortcutValidationContext(scope: .localPreviousProfile, catalog: catalog)
            ),
            .conflictsWithShortcut(label: "Open popup")
        )
    }

    func test_conflictWithNextAccount_usesNavigationLabel() {
        let candidate = def(18, [.command])
        let catalog = ShortcutCatalog(entries: [
            ShortcutCatalogEntry(
                definition: candidate,
                scope: .localNextProfile,
                label: "Next account"
            ),
        ])

        XCTAssertEqual(
            ShortcutValidator.validate(
                candidate,
                in: ShortcutValidationContext(scope: .localPreviousProfile, catalog: catalog)
            ),
            .conflictsWithShortcut(label: "Next account")
        )
    }

    @MainActor
    func test_catalogBuilder_excludesCurrentScopeWhenEditing() {
        let suiteName = "ShortcutValidatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HotKeyStore(defaults: defaults)
        let work = Profile(id: UUID(), name: "Work", authMethod: .cliSync, email: "work@example.com")

        store.setDefinition(def(40, [.command]), for: ShortcutNames.openPopup)
        store.setDefinition(def(18, [.command]), for: ShortcutNames.switchProfile(id: work.id))

        let catalog = ShortcutCatalog.make(
            store: store,
            profiles: [work],
            excluding: .localSwitchProfile(profileID: work.id)
        )

        XCTAssertNil(catalog.entry(matching: def(18, [.command])))
        XCTAssertNotNil(catalog.entry(matching: def(40, [.command])))
    }

    @MainActor
    func test_catalog_excludesHiddenDirectTabShortcutFromEffectiveEntries() {
        let suiteName = "ShortcutValidatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "display.popover.showCache")

        let store = HotKeyStore(defaults: defaults)
        let candidate = def(18, [.command])
        store.setDefinition(candidate, for: ShortcutNames.switchTab(.cache))

        let catalog = ShortcutCatalog.make(
            store: store,
            profiles: [],
            tabVisibility: PopoverTabVisibility(defaults: defaults)
        )

        XCTAssertNil(catalog.entry(matching: candidate))
    }

    @MainActor
    func test_catalog_tracksHiddenDirectTabBindingForPruning() {
        let suiteName = "ShortcutValidatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "display.popover.showCache")

        let store = HotKeyStore(defaults: defaults)
        let candidate = def(18, [.command])
        store.setDefinition(candidate, for: ShortcutNames.switchTab(.cache))

        let catalog = ShortcutCatalog.make(
            store: store,
            profiles: [],
            tabVisibility: PopoverTabVisibility(defaults: defaults)
        )

        XCTAssertEqual(catalog.hiddenBindingsToPrune(matching: candidate), [ShortcutNames.switchTab(.cache)])
    }
}
