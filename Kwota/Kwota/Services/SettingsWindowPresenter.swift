//
//  SettingsWindowPresenter.swift
//  Kwota
//

import AppKit
import Combine
import SwiftUI

/// Coordinates Settings window presentation for a menu-bar app.
///
/// Kwota runs as `LSUIElement` (no Dock icon by default), which means
/// `NSApp.activate(ignoringOtherApps:)` alone cannot raise a window above
/// the frontmost app. We temporarily flip activation policy to `.regular`
/// while Settings is visible, then revert to `.accessory` on close.
@MainActor
@Observable
final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()

    /// Pure mapping for tests + runtime callers. Only `.auto` mode lets the
    /// presenter flip between `.regular` (Settings open) and `.accessory`
    /// (Settings closed); the explicit modes are owned by `KwotaApp`.
    nonisolated static func shouldSwapForSettings(mode: DockIconMode) -> Bool {
        mode == .auto
    }

    private let dockModeStore: DockIconModeStore

    private init(dockModeStore: DockIconModeStore = DockIconModeStore()) {
        self.dockModeStore = dockModeStore
    }

    /// Initial section to show next time SettingsView appears. Read once
    /// by SettingsView.onAppear, then cleared.
    var pendingSection: SettingsSection?

    /// Optional anchor id within the pending destination. When set, the
    /// destination tab can use a ScrollViewReader to scroll to a row tagged
    /// with `.id(anchorId)`. Read once by the destination, then cleared.
    var pendingAnchorId: String?

    private var closeObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var lastAppliedTheme: DisplayTheme = .system

    /// Open Settings, optionally pre-selecting a section.
    /// Call from inside a SwiftUI view with `openWindow` from the environment.
    func present(section: SettingsSection? = nil, openWindow: OpenWindowAction) {
        if let section { pendingSection = section }

        if Self.shouldSwapForSettings(mode: dockModeStore.mode) {
            NSApp.setActivationPolicy(.regular)
        }
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)

        installCloseObserver()
    }

    /// Called by SettingsView when its window appears, to bring the
    /// existing window forward and apply transparency for the vibrancy
    /// background to show through.
    func bringToFront() {
        for window in NSApp.windows where window.identifier?.rawValue == "settings" {
            window.toolbarStyle = .unified
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Keep the Settings window's AppKit appearance in sync with SwiftUI's
    /// `.preferredColorScheme(_:)`. NavigationSplitView mixes SwiftUI detail
    /// content with AppKit visual-effect surfaces, so both layers need the same
    /// theme input.
    ///
    /// For `.system` we resolve to a *concrete* appearance (not `nil`): a nil
    /// `window.appearance` leaves the visual-effect view stale until the window
    /// is re-keyed, which is the "switch to Follow System renders half-light"
    /// bug. We then re-resolve on reactivation so Follow System still tracks an
    /// OS theme change made while Kwota was in the background.
    func applyTheme(_ theme: DisplayTheme) {
        lastAppliedTheme = theme
        installAppearanceObserver()
        applyAppearance(for: theme)
    }

    private func applyAppearance(for theme: DisplayTheme) {
        let appearance = Self.appearance(for: theme)
        for window in NSApp.windows where window.identifier?.rawValue == "settings" {
            window.appearance = appearance
            window.contentView?.needsDisplay = true
            window.displayIfNeeded()
        }
    }

    private static func appearance(for theme: DisplayTheme) -> NSAppearance? {
        switch theme {
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        case .system:
            let name = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
            return NSAppearance(named: name)
        }
    }

    private func installAppearanceObserver() {
        guard appearanceObserver == nil else { return }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applyAppearance(for: self.lastAppliedTheme)
            }
        }
    }

    private func installCloseObserver() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow,
                  window.identifier?.rawValue == "settings" else { return }
            Task { @MainActor in
                self?.handleSettingsClosed()
            }
        }
    }

    private func handleSettingsClosed() {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        if Self.shouldSwapForSettings(mode: dockModeStore.mode) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
