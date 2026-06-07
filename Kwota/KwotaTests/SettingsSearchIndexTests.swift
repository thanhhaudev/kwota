// Kwota/KwotaTests/SettingsSearchIndexTests.swift
import XCTest
@testable import Kwota

final class SettingsSearchIndexTests: XCTestCase {
    func test_empty_query_returns_no_matches() {
        XCTAssertTrue(SettingsSearchIndex.matches(for: "").isEmpty)
        XCTAssertTrue(SettingsSearchIndex.matches(for: "   ").isEmpty)
    }

    func test_exact_title_match_wins_over_alias() {
        // "cache" used to route to .dataStorage when the legacy "Cache
        // tracking" card lived there. After that card was deleted in the
        // Phase 2 #1 cleanup, search for "cache" should land on the
        // dedicated Cache tab instead.
        let top = SettingsSearchIndex.bestMatch(for: "cache")
        XCTAssertNotNil(top)
        XCTAssertEqual(top?.destination, .cache)
    }

    func test_alias_match_routes_to_owning_destination() {
        let top = SettingsSearchIndex.bestMatch(for: "battery")
        XCTAssertEqual(top?.destination, .general)
    }

    func test_destination_titles_are_indexed() {
        for section in SettingsSection.allCases {
            let top = SettingsSearchIndex.bestMatch(for: section.title)
            XCTAssertEqual(top?.destination, section,
                           "destination title not routable: \(section.title)")
        }
    }

    func test_case_and_diacritic_insensitive() {
        let lower = SettingsSearchIndex.bestMatch(for: "appearance")
        let upper = SettingsSearchIndex.bestMatch(for: "APPEARANCE")
        XCTAssertNotNil(lower)
        XCTAssertEqual(lower?.destination, upper?.destination)
    }

    func test_no_match_returns_nil() {
        XCTAssertNil(SettingsSearchIndex.bestMatch(for: "zzzzz-not-a-setting"))
    }

    // MARK: - resultGroups

    func test_resultGroups_empty_query_is_empty() {
        XCTAssertTrue(SettingsSearchIndex.resultGroups(for: "").isEmpty)
        XCTAssertTrue(SettingsSearchIndex.resultGroups(for: "   ").isEmpty)
    }

    func test_resultGroups_nonsense_query_is_empty() {
        XCTAssertTrue(SettingsSearchIndex.resultGroups(for: "zzzzz-not-a-setting").isEmpty)
    }

    func test_resultGroups_groups_anchored_items_under_their_section() {
        let groups = SettingsSearchIndex.resultGroups(for: "display")
        let display = groups.first { $0.section == .display }
        XCTAssertNotNil(display, "expected a Display group")
        XCTAssertTrue(display!.items.allSatisfy { $0.anchorId != nil })
        XCTAssertTrue(display!.items.contains { $0.title == "Display style" })
    }

    func test_resultGroups_section_only_match_has_empty_items() {
        let groups = SettingsSearchIndex.resultGroups(for: "accounts")
        let accounts = groups.first { $0.section == .profiles }
        XCTAssertNotNil(accounts)
        XCTAssertTrue(accounts!.items.isEmpty)
    }

    func test_resultGroups_ordering_is_deterministic() {
        let a = SettingsSearchIndex.resultGroups(for: "e")
        let b = SettingsSearchIndex.resultGroups(for: "e")
        XCTAssertEqual(a.map(\.section), b.map(\.section))
    }

    // MARK: - highlightRange

    func test_highlightRange_case_insensitive() {
        let title = "Battery Saver"
        let range = SettingsSearchIndex.highlightRange(of: "batt", in: title)
        XCTAssertNotNil(range)
        XCTAssertEqual(title[range!], "Batt")
    }

    func test_highlightRange_no_match_returns_nil() {
        XCTAssertNil(SettingsSearchIndex.highlightRange(of: "zzz", in: "Battery Saver"))
    }

    func test_highlightRange_empty_query_returns_nil() {
        XCTAssertNil(SettingsSearchIndex.highlightRange(of: "  ", in: "Battery Saver"))
    }

    // MARK: - suggestions

    func test_suggestions_are_curated_inner_settings() {
        let s = SettingsSearchIndex.suggestions
        XCTAssertEqual(s.map(\.anchorId), [
            "general.launch", "general.refresh", "display.theme",
            "display.menubar", "data.usagehistory",
        ])
        XCTAssertEqual(s.map(\.title), [
            "Open Kwota at login", "Battery Saver", "Appearance",
            "Display style", "Usage history",
        ])
        // Every suggestion deep-links to a specific card.
        XCTAssertTrue(s.allSatisfy { $0.anchorId != nil })
    }
}
