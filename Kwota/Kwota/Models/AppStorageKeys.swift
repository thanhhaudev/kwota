//
//  AppStorageKeys.swift
//  Kwota
//

import Foundation

/// Central catalog of `@AppStorage` / `UserDefaults` keys used across the
/// app. Adding a new persisted setting? Define its key here so other call
/// sites can't drift on the string literal. (One exception: `DockIconMode`
/// owns its store key via `DockIconModeStore.key` so the serialization
/// detail stays encapsulated with the type that defines the schema.)
enum AppStorageKeys {
    // MARK: Display
    static let displayTheme                = "display.theme"
    static let displayChartShowAvg         = "display.chart.showAvg"
    static let displayChartShowPaceHint    = "display.chart.showPaceHint"
    static let displayUsageCompact         = "display.usage.compact"
    static let displayPopoverShowAwake     = "display.popover.showAwake"
    static let displayPopoverShowCache     = "display.popover.showCache"
    static let displayPopoverShowStats     = "display.popover.showStats"

    // MARK: General
    static let generalPollingMode          = "general.pollingMode"
    static let generalMenuBarStyle         = "general.menuBarStyle"
    static let generalMenuBarUsageSource   = "general.menuBarUsageSource"
    static let generalUsageHistorySessionCap = "general.usageHistory.sessionCap"
    static let generalUsageHistoryWeeklyCap  = "general.usageHistory.weeklyCap"

    // MARK: Profiles
    static let isPrivacyMasked             = "isPrivacyMasked"

    // MARK: Awake
    static let awakeConfig = "awake.config"

    // MARK: Provider
    /// Last-selected Antigravity quota group (Gemini / Claude+GPT) in the Usage
    /// tab, so the popover reopens on the group the user last viewed. Global (not
    /// per-profile) — the group shape is the same across Antigravity accounts, and
    /// a stale key falls back to the default via `resolvedKey`.
    static let antigravityGroupSelection = "antigravity.groupSelection"
}
