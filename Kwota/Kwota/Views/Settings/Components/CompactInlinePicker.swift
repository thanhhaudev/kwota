//
//  CompactInlinePicker.swift
//  Kwota
//

import AppKit
import SwiftUI

struct CompactInlinePicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    let compact: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    init(
        selection: Binding<Value>,
        options: [Value],
        title: @escaping (Value) -> String,
        compact: Bool = false
    ) {
        self._selection = selection
        self.options = options
        self.title = title
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: compact ? 2 : 6) {
            Text(title(selection))
                .font(compact ? .callout : .system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if compact {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                chevronBadge
            }
        }
        .padding(.horizontal, compact ? 0 : 6)
        .padding(.vertical, compact ? 0 : 3)
        .frame(minHeight: compact ? 22 : nil)
        .background { if !compact { hoverBackground } }
        .contentShape(Rectangle())
        .overlay {
            HiddenNSPopUpButton(
                titles: options.map(title),
                selectedIndex: options.firstIndex(of: selection) ?? 0,
                isEnabled: isEnabled,
                onSelect: { idx in
                    guard idx >= 0, idx < options.count else { return }
                    selection = options[idx]
                }
            )
        }
        .onHover { isHovering = $0 }
        .fixedSize()
    }

    private var chevronBadge: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 18, height: 18)
            .background(
                Circle().fill(Color(nsColor: .quaternaryLabelColor))
            )
    }

    @ViewBuilder
    private var hoverBackground: some View {
        if isHovering {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor))
        }
    }
}

private struct HiddenNSPopUpButton: NSViewRepresentable {
    let titles: [String]
    let selectedIndex: Int
    let isEnabled: Bool
    let onSelect: (Int) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.alphaValue = 0.02
        button.target = context.coordinator
        button.action = #selector(Coordinator.didChange(_:))
        return button
    }

    func updateNSView(_ nsView: NSPopUpButton, context: Context) {
        if nsView.itemTitles != titles {
            nsView.removeAllItems()
            nsView.addItems(withTitles: titles)
        }
        if nsView.indexOfSelectedItem != selectedIndex,
           selectedIndex >= 0, selectedIndex < titles.count {
            nsView.selectItem(at: selectedIndex)
        }
        nsView.isEnabled = isEnabled
        context.coordinator.onSelect = onSelect
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    final class Coordinator: NSObject {
        var onSelect: (Int) -> Void

        init(onSelect: @escaping (Int) -> Void) {
            self.onSelect = onSelect
        }

        @objc func didChange(_ sender: NSPopUpButton) {
            onSelect(sender.indexOfSelectedItem)
        }
    }
}
