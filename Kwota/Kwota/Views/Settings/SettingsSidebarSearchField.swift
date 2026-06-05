//
//  SettingsSidebarSearchField.swift
//  Kwota
//

import SwiftUI

/// A native-System-Settings-style rounded search field pinned at the top of the
/// Settings sidebar. Owns the magnifier icon, clear button, and focus ring; the
/// parent owns the text + focus state and reacts to mode changes.
struct SettingsSidebarSearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    /// Called when the user presses Escape: parent decides clear-vs-defocus.
    var onEscape: () -> Void
    /// ↑/↓ navigation while the field is focused. Delta is -1 (up) or +1 (down).
    var onMoveSelection: (Int) -> KeyPress.Result
    /// Commit the highlighted result (Return) while the field is focused.
    var onCommitSelection: () -> KeyPress.Result

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused(focus)
                .onKeyPress(.downArrow) { onMoveSelection(1) }
                .onKeyPress(.upArrow) { onMoveSelection(-1) }
                .onKeyPress(.return) { onCommitSelection() }
                .onKeyPress(.escape) {
                    onEscape()
                    return .handled
                }

            if focus.wrappedValue || !text.isEmpty {
                Button {
                    text = ""
                    focus.wrappedValue = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(focus.wrappedValue ? Color.accentColor : Color.primary.opacity(0.12),
                              lineWidth: focus.wrappedValue ? 2 : 1)
        )
        // A plain TextField only focuses on its narrow glyph row; make the whole
        // capsule a click target so tapping anywhere in the pill focuses the field
        // (matching the native System Settings search field).
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = true }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}
