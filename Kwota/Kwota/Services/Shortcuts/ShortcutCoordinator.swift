//
//  ShortcutCoordinator.swift
//  Kwota
//

import Foundation

/// Owns the global "open popup" hotkey lifecycle. Per-profile switch
/// shortcuts are handled locally in `MenuBarView` via SwiftUI
/// `.keyboardShortcut` and do not flow through this coordinator.
@MainActor
@Observable
final class ShortcutCoordinator {
    private let manager: HotKeyManager
    private let opener: MenuBarExtraOpening

    init(
        manager: HotKeyManager? = nil,
        opener: MenuBarExtraOpening? = nil
    ) {
        self.manager = manager ?? HotKeyManager()
        self.opener = opener ?? LiveMenuBarExtraOpener()
    }

    /// Register the open-popup action with `HotKeyManager`. The manager
    /// reads the persisted definition (if any) and registers a Carbon
    /// hotkey. Idempotent.
    func start() {
        manager.register(name: ShortcutNames.openPopup) { [weak self] in
            self?.opener.open()
        }
    }

    /// Re-read the persisted "open popup" definition and re-register.
    /// Called by the recorder after writing a new definition to the store.
    func reloadOpenPopup() {
        manager.rebind(name: ShortcutNames.openPopup)
    }
}
