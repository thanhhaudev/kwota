import XCTest
import AppKit
@testable import Kwota

@MainActor
final class HotKeyManagerTests: XCTestCase {
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

    private var defaults: UserDefaults!
    private var store: HotKeyStore!
    private var backend: FakeBackend!
    private var manager: HotKeyManager!
    private let suiteName = "HotKeyManagerTests-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = HotKeyStore(defaults: defaults)
        backend = FakeBackend()
        manager = HotKeyManager(backend: backend, store: store)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        backend = nil
        manager = nil
        super.tearDown()
    }

    func test_register_with_no_stored_definition_does_not_call_backend() {
        manager.register(name: "openPopup", action: {})
        XCTAssertTrue(backend.registerCalls.isEmpty)
    }

    func test_register_with_stored_definition_registers_once() {
        let def = HotKeyDefinition(keyCode: 40, rawModifiers: NSEvent.ModifierFlags([.command, .option]).rawValue)
        store.setDefinition(def, for: "openPopup")

        manager.register(name: "openPopup", action: {})

        XCTAssertEqual(backend.registerCalls.count, 1)
        XCTAssertEqual(backend.registerCalls.first?.definition, def)
    }

    func test_action_fires_on_backend_invocation() {
        let def = HotKeyDefinition(keyCode: 40, rawModifiers: NSEvent.ModifierFlags.command.rawValue)
        store.setDefinition(def, for: "openPopup")
        var fired = 0
        manager.register(name: "openPopup") { fired += 1 }

        backend.active.values.first?.action()
        XCTAssertEqual(fired, 1)
    }

    func test_rebind_after_store_change_unregisters_old_then_registers_new() {
        let a = HotKeyDefinition(keyCode: 1, rawModifiers: NSEvent.ModifierFlags.command.rawValue)
        let b = HotKeyDefinition(keyCode: 2, rawModifiers: NSEvent.ModifierFlags.option.rawValue)
        store.setDefinition(a, for: "n")
        manager.register(name: "n", action: {})
        XCTAssertEqual(backend.registerCalls.count, 1)

        store.setDefinition(b, for: "n")
        manager.rebind(name: "n")

        XCTAssertEqual(backend.unregisterCalls.count, 1, "old registration must be unregistered")
        XCTAssertEqual(backend.registerCalls.count, 2)
        XCTAssertEqual(backend.registerCalls.last?.definition, b)
    }

    func test_rebind_to_nil_unregisters_only() {
        let def = HotKeyDefinition(keyCode: 1, rawModifiers: 0)
        store.setDefinition(def, for: "n")
        manager.register(name: "n", action: {})

        store.reset("n")
        manager.rebind(name: "n")

        XCTAssertEqual(backend.unregisterCalls.count, 1)
        XCTAssertEqual(backend.registerCalls.count, 1, "no second register on nil")
        XCTAssertTrue(backend.active.isEmpty)
    }

    func test_unbind_removes_registration_but_keeps_action() {
        let def = HotKeyDefinition(keyCode: 1, rawModifiers: 0)
        store.setDefinition(def, for: "n")
        var fired = 0
        manager.register(name: "n") { fired += 1 }

        manager.unbind(name: "n")
        XCTAssertEqual(backend.unregisterCalls.count, 1)

        // Re-bind without re-supplying action: action should still fire.
        manager.rebind(name: "n")
        backend.active.values.first?.action()
        XCTAssertEqual(fired, 1)
    }

    func test_unregisterAll_drops_action_too() {
        let def = HotKeyDefinition(keyCode: 1, rawModifiers: 0)
        store.setDefinition(def, for: "n")
        var fired = 0
        manager.register(name: "n") { fired += 1 }

        manager.unregisterAll(name: "n")
        manager.rebind(name: "n")  // no action stored, so still nothing happens

        XCTAssertEqual(backend.registerCalls.count, 1, "no second register without action")
        XCTAssertEqual(fired, 0)
    }

    func test_each_register_uses_unique_id() {
        let def = HotKeyDefinition(keyCode: 1, rawModifiers: 0)
        store.setDefinition(def, for: "a")
        store.setDefinition(def, for: "b")
        manager.register(name: "a", action: {})
        manager.register(name: "b", action: {})

        let ids = backend.registerCalls.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids must be unique")
    }
}
