//
//  SettingsSearchIndex.swift
//  Kwota
//

import Foundation

struct SettingsSearchEntry: Equatable {
    let title: String
    let aliases: [String]
    let destination: SettingsSection
    let anchorId: String?
}

/// A section's worth of search results: the section itself is the (implicit)
/// clickable header; `items` are the matched anchored sub-settings under it.
struct SettingsSearchResultGroup: Identifiable, Equatable {
    let section: SettingsSection
    let items: [SettingsSearchEntry]
    var id: String { section.id }
}

enum SettingsSearchIndex {
    static let all: [SettingsSearchEntry] = destinationEntries + itemEntries

    static func bestMatch(for raw: String) -> SettingsSearchEntry? {
        matches(for: raw).first
    }

    static func matches(for raw: String) -> [SettingsSearchEntry] {
        let q = normalize(raw)
        guard !q.isEmpty else { return [] }

        var scored: [(score: Int, index: Int, entry: SettingsSearchEntry)] = []
        for (index, e) in all.enumerated() {
            let title = normalize(e.title)
            let aliases = e.aliases.map(normalize)

            if title == q                      { scored.append((0, index, e)); continue }
            if title.hasPrefix(q)              { scored.append((1, index, e)); continue }
            if aliases.contains(where: { $0.hasPrefix(q) }) { scored.append((2, index, e)); continue }
            if title.contains(q)               { scored.append((3, index, e)); continue }
            if aliases.contains(where: { $0.contains(q) }) { scored.append((4, index, e)); continue }
        }
        return scored
            .sorted { ($0.score, $0.index) < ($1.score, $1.index) }
            .map(\.entry)
    }

    /// Matched entries grouped by their destination section, in rank order of
    /// each section's first appearance. The section header is implicit (render
    /// from `group.section`); `items` are the matched anchored sub-settings.
    static func resultGroups(for raw: String) -> [SettingsSearchResultGroup] {
        let entries = matches(for: raw)
        guard !entries.isEmpty else { return [] }

        var order: [SettingsSection] = []
        var itemsBySection: [SettingsSection: [SettingsSearchEntry]] = [:]
        for e in entries {
            if !order.contains(e.destination) { order.append(e.destination) }
            if e.anchorId != nil {
                itemsBySection[e.destination, default: []].append(e)
            }
        }
        return order.map {
            SettingsSearchResultGroup(section: $0, items: itemsBySection[$0] ?? [])
        }
    }

    /// Range of `raw` within `title` (case/diacritic-insensitive) for bolding
    /// the matched substring. Returns nil when there is no in-place match.
    static func highlightRange(of raw: String, in title: String) -> Range<String.Index>? {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive])
    }

    /// Curated inner settings shown as "Suggestions" when the field is focused
    /// but empty. Each deep-links to a specific card (anchorId), so the list adds
    /// value instead of duplicating the sidebar's top-level sections.
    static let suggestions: [SettingsSearchEntry] = {
        let wanted = ["general.launch", "general.refresh", "display.theme",
                      "display.menubar", "data.usagehistory"]
        return wanted.compactMap { anchor in
            itemEntries.first { $0.anchorId == anchor }
        }
    }()

    private static func normalize(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var destinationEntries: [SettingsSearchEntry] {
        SettingsSection.allCases.map {
            SettingsSearchEntry(title: $0.title, aliases: [], destination: $0, anchorId: nil)
        }
    }

    private static let itemEntries: [SettingsSearchEntry] = [
        .init(title: "Open Kwota at login",
              aliases: ["launch", "startup", "login"],
              destination: .general, anchorId: "general.launch"),
        .init(title: "Battery Saver",
              aliases: ["battery", "performance", "slow", "polling", "refresh"],
              destination: .general, anchorId: "general.refresh"),
        .init(title: "Dock Icon",
              aliases: ["dock"],
              destination: .general, anchorId: "general.dockicon"),

        .init(title: "Display style",
              aliases: ["menu bar", "indicator", "style"],
              destination: .display, anchorId: "display.menubar"),
        .init(title: "Usage source",
              aliases: ["session", "weekly", "source"],
              destination: .display, anchorId: "display.menubar"),
        .init(title: "Appearance",
              aliases: ["theme", "light", "dark", "system"],
              destination: .display, anchorId: "display.theme"),
        .init(title: "Popover tabs",
              aliases: ["awake", "cache", "tabs"],
              destination: .display, anchorId: "display.popovertabs"),
        .init(title: "Chart",
              aliases: ["average", "pace hint", "reference line"],
              destination: .display, anchorId: "display.chart"),

        .init(title: "Storage",
              aliases: ["application data", "recompute"],
              destination: .dataStorage, anchorId: "data.storage"),
        .init(title: "Usage history",
              aliases: ["entries", "session entries", "weekly entries"],
              destination: .dataStorage, anchorId: "data.usagehistory"),
        .init(title: "Account history",
              aliases: ["clear", "export", "profile"],
              destination: .dataStorage, anchorId: "data.profilehistory"),
        .init(title: "Cache",
              aliases: ["cache", "tracked folders", "auto-clean", "AI evaluation"],
              destination: .cache, anchorId: nil),
        .init(title: "Reset",
              aliases: ["delete all data", "wipe"],
              destination: .dataStorage, anchorId: "data.reset"),
    ]
}
