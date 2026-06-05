//
//  HotKeyManager.swift
//  Kwota
//

import Foundation

/// Tracks `name -> (action, registered id)` and re-binds when the store
/// changes. Consumers register an action once via `register(name:action:)`;
/// after the user re-records the shortcut, the recorder calls
/// `rebind(name:)` to pick up the new definition.
@MainActor
@Observable
final class HotKeyManager {
    private let backend: HotKeyBackend
    private let store: HotKeyStore
    private var actions: [String: () -> Void] = [:]
    private var nameToID: [String: UInt32] = [:]
    private var nextID: UInt32 = 1

    init(
        backend: HotKeyBackend? = nil,
        store: HotKeyStore? = nil
    ) {
        self.backend = backend ?? CarbonHotKeyBackend()
        self.store = store ?? HotKeyStore()
    }

    /// Remember the action for `name` and bind from the current stored
    /// definition. Idempotent — re-registering with the same name replaces
    /// the action and re-binds.
    func register(name: String, action: @escaping () -> Void) {
        actions[name] = action
        rebind(name: name)
    }

    /// Re-read the persisted definition for `name`; unregister the previous
    /// hotkey (if any), then register against the new definition. Called
    /// after the user records a new shortcut.
    func rebind(name: String) {
        unbind(name: name)
        guard let definition = store.definition(for: name),
              let action = actions[name] else { return }
        let id = nextID
        nextID &+= 1
        if backend.register(definition: definition, id: id, action: action) {
            nameToID[name] = id
        }
    }

    /// Unregister the hotkey but keep the action — a later `rebind(name:)`
    /// will reuse the same closure once a definition is set again.
    func unbind(name: String) {
        guard let id = nameToID.removeValue(forKey: name) else { return }
        backend.unregister(id: id)
    }

    /// Drop both the hotkey registration and the stored action.
    func unregisterAll(name: String) {
        unbind(name: name)
        actions.removeValue(forKey: name)
    }
}
