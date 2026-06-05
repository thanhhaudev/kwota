//
//  SettingsView.swift
//  Kwota
//

import SwiftUI
import AppKit
import Combine

enum SettingsSection: String, CaseIterable, Identifiable {
    case profiles
    case awake
    case cache
    case general
    case shortcuts
    case display
    case notifications
    case dataStorage
    case about
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profiles:      return "Profiles"
        case .awake:         return "Awake"
        case .cache:         return "Cache"
        case .general:       return "General"
        case .shortcuts:     return "Shortcuts"
        case .display:       return "Display"
        case .notifications: return "Notifications"
        case .dataStorage:   return "Data & Storage"
        case .about:         return "About"
        case .debug:         return "Debug"
        }
    }

    var icon: String {
        switch self {
        case .profiles:      return "person.2.fill"
        case .awake:         return "cup.and.saucer.fill"
        case .cache:         return "internaldrive.fill"
        case .general:       return "gearshape.fill"
        case .shortcuts:     return "keyboard.fill"
        case .display:       return "paintbrush.fill"
        case .notifications: return "bell.fill"
        case .dataStorage:   return "archivebox.fill"
        case .about:         return "info.circle.fill"
        case .debug:         return "ladybug.fill"
        }
    }

    var isBottomBarItem: Bool {
        switch self {
        case .about, .debug: return true
        default: return false
        }
    }
}

struct SettingsView: View {
    let vm: MenuBarViewModel
    @State private var selection: SettingsSection = .profiles
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var selectedIndex: Int = 0
    @State private var searchRows: [SettingsSearchRow] = []
    /// Gates the suggestions popover until after the window has settled, so the
    /// initial AppKit auto-focus on open doesn't flash the popover for a frame.
    @State private var suggestionsArmed = false
    private let presenter = SettingsWindowPresenter.shared
    @AppStorage(AppStorageKeys.displayTheme) private var themeRaw: String = DisplayTheme.system.rawValue
    private var theme: DisplayTheme { DisplayTheme.resolve(themeRaw) }

    /// Current OS appearance, used to resolve Follow System to a concrete scheme.
    /// Refreshed on appear/activation so it tracks an OS change made while away.
    @State private var systemIsDark = SettingsView.detectSystemDark()

    /// A *concrete* scheme for every mode — including Follow System. Passing nil
    /// to `.preferredColorScheme` (the old system value) makes SwiftUI reset the
    /// window appearance the presenter just set, leaving the sidebar's
    /// NSVisualEffectView stale until the window is re-keyed.
    private var effectiveColorScheme: ColorScheme {
        switch theme {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return systemIsDark ? .dark : .light
        }
    }

    private static func detectSystemDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The user is typing a query: the sidebar list is replaced by live results.
    private var isTyping: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Empty field but focused: show the curated suggestions as a dropdown popover
    /// over the still-visible sidebar list (matching native System Settings).
    private var showSuggestions: Bool {
        suggestionsArmed && !isTyping && isSearchFocused
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // The search field lives in the normal view hierarchy (not in a
                // `.safeAreaInset` closure) so its `.focused($isSearchFocused)`
                // binding stays connected to the @FocusState owned here — inside a
                // safeAreaInset the binding is hosted separately and never focuses.
                SettingsSidebarSearchField(
                    text: $searchText,
                    focus: $isSearchFocused,
                    onEscape: handleEscape,
                    onMoveSelection: moveSelection,
                    onCommitSelection: commitSelection
                )

                Group {
                    if isTyping {
                        SettingsSidebarSearchContent(
                            query: searchText,
                            selectedIndex: selectedIndex,
                            onRowsChange: { rows in
                                searchRows = rows
                                if selectedIndex >= rows.count { selectedIndex = 0 }
                            },
                            onCommit: commit(row:)
                        )
                    } else {
                        List(selection: $selection) {
                            ForEach([
                                SettingsSection.profiles,
                                .awake,
                                .cache,
                                .general,
                                .shortcuts,
                                .display,
                                .notifications,
                                .dataStorage,
                            ]) { section in
                                SidebarRow(section: section,
                                           isSelected: selection == section)
                                    .tag(section)
                            }
                        }
                        .listStyle(.sidebar)
                    }
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if showSuggestions {
                        SettingsSuggestionsPopover(onSelect: { commit(entry: $0) })
                            .zIndex(1)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !isTyping {
                        BottomBar(selection: $selection)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch selection {
                case .profiles:      ManageProfilesView(vm: vm)
                case .awake:         AwakeTabView(vm: vm)
                case .cache:         CacheSettingsView(vm: vm)
                case .general:       GeneralTabView(vm: vm)
                case .shortcuts:     ShortcutsTabView(vm: vm)
                case .display:       DisplayTabView(vm: vm)
                case .notifications: NotificationsTabView(vm: vm)
                case .dataStorage:   DataStorageTabView(vm: vm)
                case .about:         AboutTabView(vm: vm)
                case .debug:         DebugPanelView(vm: vm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(selection.title)
        }
        .frame(minWidth: 820, minHeight: 560)
        // Keep SwiftUI's color-scheme environment and AppKit's visual-effect
        // appearance on the same concrete scheme. NavigationSplitView mixes both;
        // a nil scheme (old Follow System value) desyncs them.
        .preferredColorScheme(effectiveColorScheme)
        .onAppear {
            if let pending = presenter.pendingSection {
                selection = pending
                presenter.pendingSection = nil
            }
            systemIsDark = Self.detectSystemDark()
            presenter.bringToFront()
            presenter.applyTheme(theme)
            // macOS tries to make the search field first responder on open. Until
            // the window settles we reject that focus (see .onChange below) and keep
            // the popover disarmed, so the field starts unfocused on launch. Real
            // user focus only takes effect once armed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                suggestionsArmed = true
            }
        }
        .onChange(of: isSearchFocused) { _, focused in
            // Bounce the launch-time auto-focus; genuine clicks land after arming.
            if focused && !suggestionsArmed {
                isSearchFocused = false
            }
        }
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
        .onChange(of: themeRaw) { _, newValue in
            presenter.applyTheme(DisplayTheme.resolve(newValue))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Track an OS appearance change made while Kwota was in the background
            // so Follow System re-resolves to the right concrete scheme.
            systemIsDark = Self.detectSystemDark()
        }
    }

    /// Navigate to a chosen search/suggestion row, reusing the existing
    /// anchor-scroll mechanism, then reset the search UI to Normal mode.
    private func commit(row: SettingsSearchRow) {
        selection = row.section
        presenter.pendingAnchorId = row.anchorId
        searchText = ""
        selectedIndex = 0
        isSearchFocused = false
    }

    /// Navigate to a suggested inner setting (deep-linking via its anchor), then
    /// reset and dismiss the popover.
    private func commit(entry: SettingsSearchEntry) {
        selection = entry.destination
        presenter.pendingAnchorId = entry.anchorId
        searchText = ""
        selectedIndex = 0
        isSearchFocused = false
    }

    private func commitSelection() -> KeyPress.Result {
        guard isTyping, searchRows.indices.contains(selectedIndex) else { return .ignored }
        commit(row: searchRows[selectedIndex])
        return .handled
    }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard isTyping, !searchRows.isEmpty else { return .ignored }
        let count = searchRows.count
        selectedIndex = (selectedIndex + delta + count) % count
        return .handled
    }

    /// Escape clears a non-empty query; on an already-empty field it drops focus,
    /// returning the sidebar to Normal mode.
    private func handleEscape() {
        if searchText.isEmpty {
            isSearchFocused = false
        } else {
            searchText = ""
            selectedIndex = 0
        }
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            SettingsSectionIcon(section: section, size: 22)

            Text(section.title)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private struct BottomBar: View {
    @Binding var selection: SettingsSection
    @State private var hovered: String?

    private var items: [SettingsSection] {
        SettingsSection.allCases.filter { $0.isBottomBarItem }
    }

    var body: some View {
        VStack(spacing: 6) {
            Divider()

            HStack(spacing: 0) {
                ForEach(items) { section in
                    Button {
                        selection = section
                    } label: {
                        bottomLabel(
                            icon: section.icon,
                            label: section.title,
                            isSelected: selection == section,
                            isHovered: hovered == section.rawValue
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? section.rawValue : nil }
                }

                Button {
                    NSApp.terminate(nil)
                } label: {
                    bottomLabel(
                        icon: "power",
                        label: "Quit",
                        isSelected: false,
                        isHovered: hovered == "quit",
                        hoverColor: Color.red.opacity(0.12)
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? "quit" : nil }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func bottomLabel(
        icon: String,
        label: String,
        isSelected: Bool,
        isHovered: Bool,
        hoverColor: Color? = nil
    ) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
            Text(label)
                .font(.system(size: 10))
        }
        .foregroundStyle(isSelected ? Color.white : .secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected
                      ? Color.accentColor
                      : (isHovered ? (hoverColor ?? Color.primary.opacity(0.06)) : .clear))
        )
        .contentShape(Rectangle())
        .help(label)
        .accessibilityLabel(label)
    }
}
