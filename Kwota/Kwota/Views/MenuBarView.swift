//
//  MenuBarView.swift
//  Kwota
//

import SwiftUI
import AppKit

struct MenuBarView: View {
    /// Fixed popover content width, shared so nested overlays can clamp to it.
    static let popoverWidth: CGFloat = 400
    /// Name of the popover-root coordinate space used for edge-clamping overlays.
    static let popoverCoordinateSpace = "kwotaPopover"

    private enum LocalShortcutAction {
        case nextTab
        case previousTab
        case switchTab(MenuBarViewModel.Tab)
        case nextProfile
        case previousProfile
        case switchProfile(UUID)
    }

    let vm: MenuBarViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.displayScale) private var displayScale
    @AppStorage(AppStorageKeys.displayTheme) private var themeRaw: String = DisplayTheme.system.rawValue
    @AppStorage(AppStorageKeys.displayPopoverShowStats) private var showStats: Bool = true
    @AppStorage(AppStorageKeys.displayPopoverShowAwake) private var showAwake: Bool = true
    @AppStorage(AppStorageKeys.displayPopoverShowCache) private var showCache: Bool = true
    @State private var localShortcutMonitor: Any?
    private let hotKeyStore = HotKeyStore()

    private var visibleTabs: [MenuBarViewModel.Tab] {
        _ = showStats
        _ = showAwake
        _ = showCache
        return PopoverTabVisibility().visibleTabs
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            tabContent
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Button {
                    SettingsWindowPresenter.shared.present(openWindow: openWindow)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .buttonStyle(.plain)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: Self.popoverWidth)
        // MenuBarExtra(.window) reuses one window across opens and caches each
        // view's rasterized layer keyed on identity, not on the window's backing
        // scale. After a first open on a 2x screen, reopening on a 1x screen
        // reuses the stale 2x bitmaps (blurry) because the content is unchanged.
        // Re-identifying the tree on displayScale change forces SwiftUI to
        // discard those layers and re-rasterize at the current scale.
        .id(displayScale)
        // Lets nested overlays (e.g. the switcher bar tooltip) measure their
        // position within the fixed-width popover so they can clamp to its edges.
        .coordinateSpace(.named(Self.popoverCoordinateSpace))
        .onChange(of: showStats) { _, _ in resetSelectionIfHidden() }
        .onChange(of: showAwake) { _, _ in resetSelectionIfHidden() }
        .onChange(of: showCache) { _, _ in resetSelectionIfHidden() }
        .onAppear {
            installLocalShortcutMonitor()
            vm.popoverDidOpen()
        }
        .onDisappear {
            removeLocalShortcutMonitor()
            vm.popoverDidClose()
        }
        .preferredColorScheme(DisplayTheme.resolve(themeRaw).colorScheme)
    }

    private func resetSelectionIfHidden() {
        if !visibleTabs.contains(vm.selectedTab) {
            vm.selectedTab = .usage
        }
    }

    private func installLocalShortcutMonitor() {
        guard localShortcutMonitor == nil else { return }
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleLocalShortcut(event)
        }
    }

    private func removeLocalShortcutMonitor() {
        if let localShortcutMonitor {
            NSEvent.removeMonitor(localShortcutMonitor)
            self.localShortcutMonitor = nil
        }
    }

    private func handleLocalShortcut(_ event: NSEvent) -> NSEvent? {
        guard let action = matchingLocalShortcut(for: event) else {
            return event
        }

        do {
            switch action {
            case .switchTab(let tab):
                guard visibleTabs.contains(tab) else { return nil }
                vm.selectedTab = tab
            case .nextTab:
                guard let tab = PopupTabNavigator.nextTab(from: vm.selectedTab, in: visibleTabs) else {
                    return nil
                }
                vm.selectedTab = tab
            case .previousTab:
                guard let tab = PopupTabNavigator.previousTab(from: vm.selectedTab, in: visibleTabs) else {
                    return nil
                }
                vm.selectedTab = tab
            case .switchProfile(let profileID):
                try vm.profileStore.setActive(id: profileID)
            case .nextProfile:
                guard let profileID = ProfileNavigator.nextProfileID(
                    from: vm.profileStore.activeProfileId,
                    in: vm.profileStore.profiles
                ) else {
                    return nil
                }
                try vm.profileStore.setActive(id: profileID)
            case .previousProfile:
                guard let profileID = ProfileNavigator.previousProfileID(
                    from: vm.profileStore.activeProfileId,
                    in: vm.profileStore.profiles
                ) else {
                    return nil
                }
                try vm.profileStore.setActive(id: profileID)
            }
        } catch {
            AppLog.shared.log(
                "MenuBarView: failed to handle local shortcut: \(error)",
                level: .error
            )
        }
        return nil
    }

    private func matchingLocalShortcut(for event: NSEvent) -> LocalShortcutAction? {
        let definition = HotKeyDefinition(
            keyCode: event.keyCode,
            rawModifiers: event.modifierFlags.rawValue
        )

        for tab in visibleTabs {
            if hotKeyStore.definition(for: ShortcutNames.switchTab(tab)) == definition {
                return .switchTab(tab)
            }
        }

        if hotKeyStore.definition(for: ShortcutNames.nextTab) == definition {
            return .nextTab
        }
        if hotKeyStore.definition(for: ShortcutNames.previousTab) == definition {
            return .previousTab
        }

        if hotKeyStore.definition(for: ShortcutNames.nextProfile) == definition {
            return .nextProfile
        }
        if hotKeyStore.definition(for: ShortcutNames.previousProfile) == definition {
            return .previousProfile
        }

        // Dormant hotkeys for offline accounts must not fire — those rows
        // are hidden from Shortcuts settings, so firing them would switch
        // to an account the user can't even see in the popover switcher
        // (and the subsequent fetch would fail anyway).
        let live = ProfileLivenessContext(
            claudeCLIEmail: vm.cliAccountWatcher.current?.email,
            codexCLIEmail: vm.codexAccountWatcher.current?.email,
            antigravityProcessAlive: vm.antigravityProcessWatcher.current != nil
        )
        for profile in vm.profileStore.profiles
            where profile.kind == .auto
            && ProfileRowPresentation.isLive(profile, liveness: live) {
            guard let storedDefinition = hotKeyStore.definition(
                for: ShortcutNames.switchProfile(id: profile.id)
            ) else {
                continue
            }
            if storedDefinition == definition {
                return .switchProfile(profile.id)
            }
        }
        return nil
    }

    private var tabContent: some View {
        Group {
            switch vm.selectedTab {
            case .usage: UsageTabView(vm: vm)
            case .awake: KeepAwakeTabView(vm: vm)
            case .cache: CacheTabView(vm: vm)
            case .stats: StatsTabView(vm: vm)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// Custom segmented control — `Picker(.segmented)` on macOS drops the
    /// `Label` systemImage, so we render icon + text ourselves to match the
    /// design intent (one row of icon + noun per tab).
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(visibleTabs) { tab in
                tabButton(tab)
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func tabButton(_ tab: MenuBarViewModel.Tab) -> some View {
        let isSelected = vm.selectedTab == tab
        Button {
            vm.selectedTab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .imageScale(.small)
                Text(tab.label)
            }
            .font(.callout)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundStyle(isSelected ? Color.white : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
