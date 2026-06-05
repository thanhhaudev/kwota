import XCTest
import AppKit
@testable import Kwota

@MainActor
final class ShortcutCoordinatorTests: XCTestCase {
    private final class FakeBackend: HotKeyBackend {
        struct Registration {
            let id: UInt32
            let definition: HotKeyDefinition
            let action: () -> Void
        }
        var active: [UInt32: Registration] = [:]
        var registerCalls: [Registration] = []
        var unregisterCalls: [UInt32] = []

        func register(definition: HotKeyDefinition, id: UInt32, action: @escaping () -> Void) -> Bool {
            let reg = Registration(id: id, definition: definition, action: action)
            active[id] = reg
            registerCalls.append(reg)
            return true
        }

        func unregister(id: UInt32) {
            active[id] = nil
            unregisterCalls.append(id)
        }
    }

    private final class FakeOpener: MenuBarExtraOpening {
        var openCount = 0
        var visible = false
        func open() { openCount += 1 }
        func isPopupVisible() -> Bool { visible }
    }

    private var defaults: UserDefaults!
    private var store: HotKeyStore!
    private var backend: FakeBackend!
    private var manager: HotKeyManager!
    private var opener: FakeOpener!
    private var coordinator: ShortcutCoordinator!
    private let suiteName = "ShortcutCoordinatorTests-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = HotKeyStore(defaults: defaults)
        backend = FakeBackend()
        manager = HotKeyManager(backend: backend, store: store)
        opener = FakeOpener()
        coordinator = ShortcutCoordinator(manager: manager, opener: opener)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        backend = nil
        manager = nil
        opener = nil
        coordinator = nil
        super.tearDown()
    }

    func test_start_with_no_definition_does_not_register() {
        coordinator.start()
        XCTAssertTrue(backend.registerCalls.isEmpty)
    }

    func test_start_with_definition_registers_open_popup() {
        let def = HotKeyDefinition(keyCode: 40, rawModifiers: NSEvent.ModifierFlags([.command, .option]).rawValue)
        store.setDefinition(def, for: ShortcutNames.openPopup)
        coordinator.start()

        XCTAssertEqual(backend.registerCalls.count, 1)
        XCTAssertEqual(backend.registerCalls.first?.definition, def)
    }

    func test_callback_invokes_opener() {
        let def = HotKeyDefinition(keyCode: 40, rawModifiers: NSEvent.ModifierFlags.command.rawValue)
        store.setDefinition(def, for: ShortcutNames.openPopup)
        coordinator.start()

        backend.active.values.first?.action()
        XCTAssertEqual(opener.openCount, 1)
    }

    func test_reloadOpenPopup_after_store_change_swaps_registration() {
        let a = HotKeyDefinition(keyCode: 1, rawModifiers: NSEvent.ModifierFlags.command.rawValue)
        let b = HotKeyDefinition(keyCode: 2, rawModifiers: NSEvent.ModifierFlags.option.rawValue)
        store.setDefinition(a, for: ShortcutNames.openPopup)
        coordinator.start()
        XCTAssertEqual(backend.registerCalls.count, 1)

        store.setDefinition(b, for: ShortcutNames.openPopup)
        coordinator.reloadOpenPopup()

        XCTAssertEqual(backend.unregisterCalls.count, 1)
        XCTAssertEqual(backend.registerCalls.count, 2)
        XCTAssertEqual(backend.registerCalls.last?.definition, b)
    }

    func test_reloadOpenPopup_to_nil_unregisters() {
        let def = HotKeyDefinition(keyCode: 1, rawModifiers: NSEvent.ModifierFlags.command.rawValue)
        store.setDefinition(def, for: ShortcutNames.openPopup)
        coordinator.start()

        store.reset(ShortcutNames.openPopup)
        coordinator.reloadOpenPopup()

        XCTAssertEqual(backend.unregisterCalls.count, 1)
        XCTAssertTrue(backend.active.isEmpty)
    }
}
