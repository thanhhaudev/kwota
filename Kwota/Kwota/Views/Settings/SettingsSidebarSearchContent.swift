//
//  SettingsSidebarSearchContent.swift
//  Kwota
//

import SwiftUI

/// One selectable row in the search/suggestions sidebar. A row either navigates
/// to a section root (`anchorId == nil`) or to a specific anchored setting.
struct SettingsSearchRow: Identifiable, Equatable {
    let id: Int                 // flat position, used for keyboard selection
    let section: SettingsSection
    let title: String
    let anchorId: String?
    let isHeader: Bool          // section header vs. indented sub-item
    let query: String           // for substring highlighting
}

/// Renders the sidebar body while the user is typing a query: grouped live
/// results, or the No-Results empty state. (Empty-query suggestions are a
/// separate popover.) The parent owns `selectedIndex` (keyboard cursor) and is
/// notified of the flat row list via `onRowsChange` so it can clamp/commit.
struct SettingsSidebarSearchContent: View {
    let query: String
    let selectedIndex: Int
    let onRowsChange: ([SettingsSearchRow]) -> Void
    let onCommit: (SettingsSearchRow) -> Void

    private var rows: [SettingsSearchRow] { resultRows }

    var body: some View {
        Group {
            if rows.isEmpty {
                noResults
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(rows) { row in
                                rowView(row)
                                    .id(row.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selectedIndex) { _, new in
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
                    }
                }
            }
        }
        .onAppear { onRowsChange(rows) }
        .onChange(of: query) { _, _ in onRowsChange(rows) }
    }

    // MARK: - Rows

    private var resultRows: [SettingsSearchRow] {
        var out: [SettingsSearchRow] = []
        var i = 0
        for group in SettingsSearchIndex.resultGroups(for: query) {
            out.append(SettingsSearchRow(id: i, section: group.section, title: group.section.title,
                                         anchorId: nil, isHeader: true, query: query))
            i += 1
            for item in group.items {
                out.append(SettingsSearchRow(id: i, section: group.section, title: item.title,
                                             anchorId: item.anchorId, isHeader: false, query: query))
                i += 1
            }
        }
        return out
    }

    // MARK: - Row view

    @ViewBuilder
    private func rowView(_ row: SettingsSearchRow) -> some View {
        let isSelected = row.id == selectedIndex
        Button {
            onCommit(row)
        } label: {
            HStack(spacing: 8) {
                if row.isHeader {
                    SettingsSectionIcon(section: row.section)
                    highlightedText(row)
                        .font(.system(size: 13, weight: .medium))
                } else {
                    highlightedText(row)
                        .font(.system(size: 13))
                        .padding(.leading, 28)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Bolds the matched substring of `row.title` against `row.query`.
    private func highlightedText(_ row: SettingsSearchRow) -> Text {
        guard !row.query.isEmpty,
              let range = SettingsSearchIndex.highlightRange(of: row.query, in: row.title) else {
            return Text(row.title)
        }
        let pre = String(row.title[row.title.startIndex..<range.lowerBound])
        let mid = String(row.title[range])
        let post = String(row.title[range.upperBound..<row.title.endIndex])
        return Text(pre) + Text(mid).fontWeight(.bold) + Text(post)
    }

    // MARK: - Empty state

    private var noResults: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No Results for \u{201C}\(query)\u{201D}")
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("Check the spelling or try a new search.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }
}
