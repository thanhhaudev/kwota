//
//  MenuBarExtraOpener.swift
//  Kwota
//

import AppKit

/// Protocol so consumers (e.g. `ShortcutCoordinator`) can be tested with a
/// fake. The default `LiveMenuBarExtraOpener` forwards to the real enum.
@MainActor
protocol MenuBarExtraOpening {
    func open()
    func isPopupVisible() -> Bool
}

struct LiveMenuBarExtraOpener: MenuBarExtraOpening {
    func open() { MenuBarExtraOpener.open() }
    func isPopupVisible() -> Bool { MenuBarExtraOpener.isPopupVisible() }
}

/// Programmatic open / visibility check for the SwiftUI `MenuBarExtra`
/// popup. SwiftUI does not expose a public API for this; we locate the
/// status-item window by class/title name and call `performClick(_:)` on
/// the contained `NSStatusBarButton`.
///
/// On failure we log and no-op rather than throw — the caller (a global
/// hotkey handler) cannot meaningfully recover.
@MainActor
enum MenuBarExtraOpener {
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        guard let button = findStatusItemButton(in: NSApp.windows) else {
            AppLog.shared.log("MenuBarExtraOpener: status item not found", level: .error)
            return
        }
        button.performClick(nil)
    }

    static func isPopupVisible() -> Bool {
        isPopupVisible(in: NSApp.windows)
    }

    // MARK: - Pure helpers (testable)

    static func findStatusItemButton(in windows: [NSWindow]) -> NSStatusBarButton? {
        for window in windows where isMenuBarExtraWindow(window) {
            if let button = scanForStatusBarButton(window.contentView) {
                return button
            }
        }
        return nil
    }

    static func isPopupVisible(in windows: [NSWindow]) -> Bool {
        windows.contains { isMenuBarExtraWindow($0) && $0.isVisible }
    }

    private static func isMenuBarExtraWindow(_ window: NSWindow) -> Bool {
        let className = String(describing: type(of: window))
        if className.contains("MenuBarExtra") || className.contains("StatusBar") {
            return true
        }
        let title = window.title
        if title.contains("MenuBarExtra") || title.contains("StatusBar") {
            return true
        }
        return false
    }

    private static func scanForStatusBarButton(_ view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let found = scanForStatusBarButton(subview) { return found }
        }
        return nil
    }
}
