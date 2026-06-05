//
//  MenuBarStylePreviewTile.swift
//  Kwota
//

import SwiftUI

/// Visual preview of one MenuBarStyle option. Selecting it sets the live
/// style. The preview renders the same SwiftUI view tree the live menu-bar
/// icon uses (via `MenuBarIconRenderer.makeContent`), driven by the live
/// reading from the menu-bar driver, so what users see in the tile matches
/// what's currently in their menu bar.
struct MenuBarStylePreviewTile: View {
    struct SelectionState {
        let tile: MenuBarStyle
        let current: MenuBarStyle
        var isSelected: Bool { tile == current }
    }

    let style: MenuBarStyle
    let current: MenuBarStyle
    let reading: MenuBarReading
    let onSelect: () -> Void

    private var state: SelectionState {
        SelectionState(tile: style, current: current)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                    MenuBarIconRenderer.makeContent(style: style, reading: reading)
                }
                .frame(width: 72, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(state.isSelected
                                      ? Color.accentColor
                                      : Color(nsColor: .separatorColor).opacity(0.6),
                                      lineWidth: state.isSelected ? 2 : 0.5)
                )

                Text(style.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(state.isSelected ? [.isSelected] : [])
    }
}
