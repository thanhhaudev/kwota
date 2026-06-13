//
//  PopoverTabVisibility.swift
//  Kwota
//

import Foundation

struct PopoverTabVisibility {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var visibleTabs: [MenuBarViewModel.Tab] {
        MenuBarViewModel.Tab.allCases.filter(isVisible(_:))
    }

    func isVisible(_ tab: MenuBarViewModel.Tab) -> Bool {
        switch tab {
        case .usage:
            true
        case .awake:
            defaults.object(forKey: AppStorageKeys.displayPopoverShowAwake) as? Bool ?? true
        case .cache:
            defaults.object(forKey: AppStorageKeys.displayPopoverShowCache) as? Bool ?? true
        case .stats:
            true
        }
    }
}

enum PopupTabNavigator {
    static func nextTab(
        from selectedTab: MenuBarViewModel.Tab,
        in visibleTabs: [MenuBarViewModel.Tab]
    ) -> MenuBarViewModel.Tab? {
        targetTab(moving: 1, from: selectedTab, in: visibleTabs)
    }

    static func previousTab(
        from selectedTab: MenuBarViewModel.Tab,
        in visibleTabs: [MenuBarViewModel.Tab]
    ) -> MenuBarViewModel.Tab? {
        targetTab(moving: -1, from: selectedTab, in: visibleTabs)
    }

    private static func targetTab(
        moving delta: Int,
        from selectedTab: MenuBarViewModel.Tab,
        in visibleTabs: [MenuBarViewModel.Tab]
    ) -> MenuBarViewModel.Tab? {
        guard visibleTabs.count > 1 else { return nil }

        if let currentIndex = visibleTabs.firstIndex(of: selectedTab) {
            let nextIndex = (currentIndex + delta + visibleTabs.count) % visibleTabs.count
            return visibleTabs[nextIndex]
        }

        return delta > 0 ? visibleTabs.first : visibleTabs.last
    }
}
