import XCTest
import AppKit
@testable import Kwota

final class HotKeyStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "HotKeyStoreTests-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_returns_nil_when_unset() {
        let store = HotKeyStore(defaults: defaults)
        XCTAssertNil(store.definition(for: "openPopup"))
    }

    func test_set_and_retrieve() {
        let store = HotKeyStore(defaults: defaults)
        let def = HotKeyDefinition(keyCode: 40, rawModifiers: NSEvent.ModifierFlags([.command, .option]).rawValue)
        store.setDefinition(def, for: "openPopup")
        XCTAssertEqual(store.definition(for: "openPopup"), def)
    }

    func test_setDefinition_nil_clears() {
        let store = HotKeyStore(defaults: defaults)
        let def = HotKeyDefinition(keyCode: 40, rawModifiers: NSEvent.ModifierFlags.command.rawValue)
        store.setDefinition(def, for: "openPopup")
        store.setDefinition(nil, for: "openPopup")
        XCTAssertNil(store.definition(for: "openPopup"))
    }

    func test_reset_alias() {
        let store = HotKeyStore(defaults: defaults)
        store.setDefinition(HotKeyDefinition(keyCode: 1, rawModifiers: 0), for: "x")
        store.reset("x")
        XCTAssertNil(store.definition(for: "x"))
    }

    func test_isolated_per_name() {
        let store = HotKeyStore(defaults: defaults)
        let a = HotKeyDefinition(keyCode: 1, rawModifiers: NSEvent.ModifierFlags.command.rawValue)
        let b = HotKeyDefinition(keyCode: 2, rawModifiers: NSEvent.ModifierFlags.option.rawValue)
        store.setDefinition(a, for: "alpha")
        store.setDefinition(b, for: "beta")
        XCTAssertEqual(store.definition(for: "alpha"), a)
        XCTAssertEqual(store.definition(for: "beta"), b)
    }

    func test_corrupt_value_returns_nil() {
        let store = HotKeyStore(defaults: defaults)
        defaults.set("not json", forKey: "hotkey.bogus")
        XCTAssertNil(store.definition(for: "bogus"))
    }

    func test_names_withPrefix_returnsStoredShortcutNames() {
        let store = HotKeyStore(defaults: defaults)
        store.setDefinition(
            HotKeyDefinition(keyCode: 18, rawModifiers: NSEvent.ModifierFlags.command.rawValue),
            for: ShortcutNames.nextProfile
        )
        store.setDefinition(
            HotKeyDefinition(keyCode: 19, rawModifiers: NSEvent.ModifierFlags.command.rawValue),
            for: ShortcutNames.switchProfile(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        )
        store.setDefinition(
            HotKeyDefinition(keyCode: 20, rawModifiers: NSEvent.ModifierFlags.command.rawValue),
            for: ShortcutNames.switchProfile(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        )

        XCTAssertEqual(
            Set(store.names(withPrefix: "switchProfile.")),
            Set([
                "switchProfile.AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                "switchProfile.BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            ])
        )
    }
}
