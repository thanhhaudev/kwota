import XCTest
@testable import Kwota

/// Pins the per-family / per-effort sort order surfaced by
/// `AntigravityModelSortKey.from(label:)`. The view sorts the model rows
/// so that Gemini Pro variants land first (Low → High), followed by Gemini
/// Flash variants (Low → Medium → High), then Claude family, then GPT.
final class AntigravityModelSortTests: XCTestCase {
    func test_geminiProBeforeFlash() {
        let pro = AntigravityModelSortKey.from(label: "Gemini 3.1 Pro (High)")
        let flash = AntigravityModelSortKey.from(label: "Gemini 3.5 Flash (Low)")
        XCTAssertLessThan(pro.family, flash.family)
    }

    func test_flashBeforeClaude() {
        let flash = AntigravityModelSortKey.from(label: "Gemini 3.5 Flash (High)")
        let claude = AntigravityModelSortKey.from(label: "Claude Sonnet 4.6 (Thinking)")
        XCTAssertLessThan(flash.family, claude.family)
    }

    func test_claudeBeforeGPT() {
        let claude = AntigravityModelSortKey.from(label: "Claude Opus 4.6 (Thinking)")
        let gpt = AntigravityModelSortKey.from(label: "GPT-OSS 120B (Medium)")
        XCTAssertLessThan(claude.family, gpt.family)
    }

    func test_effortOrder_lowMediumHighThinking() {
        XCTAssertEqual(AntigravityModelSortKey.from(label: "Gemini 3.5 Flash (Low)").effort, 0)
        XCTAssertEqual(AntigravityModelSortKey.from(label: "Gemini 3.5 Flash (Medium)").effort, 1)
        XCTAssertEqual(AntigravityModelSortKey.from(label: "Gemini 3.5 Flash (High)").effort, 2)
        XCTAssertEqual(AntigravityModelSortKey.from(label: "Claude Sonnet 4.6 (Thinking)").effort, 3)
    }

    func test_unknownLabelFallsToTail() {
        // No family token → bucket 99, sorts to the end of the list.
        let key = AntigravityModelSortKey.from(label: "Some Future Model (Mega)")
        XCTAssertEqual(key.family, 99)
        XCTAssertEqual(key.effort, 99)
    }

    func test_nilLabel_isUnknown() {
        let key = AntigravityModelSortKey.from(label: nil)
        XCTAssertEqual(key.family, 99)
        XCTAssertEqual(key.effort, 99)
    }

    /// Realistic end-to-end ordering for the 8 wire-observed models.
    func test_fullOrdering_realisticWireSet() {
        let inputs = [
            "Gemini 3.1 Pro (High)",
            "Claude Sonnet 4.6 (Thinking)",
            "Claude Opus 4.6 (Thinking)",
            "GPT-OSS 120B (Medium)",
            "Gemini 3.5 Flash (Medium)",
            "Gemini 3.5 Flash (High)",
            "Gemini 3.5 Flash (Low)",
            "Gemini 3.1 Pro (Low)",
        ]
        let sorted = inputs.sorted { a, b in
            let ka = AntigravityModelSortKey.from(label: a)
            let kb = AntigravityModelSortKey.from(label: b)
            if ka.family != kb.family { return ka.family < kb.family }
            if ka.effort != kb.effort { return ka.effort < kb.effort }
            return a < b
        }
        XCTAssertEqual(sorted, [
            "Gemini 3.1 Pro (Low)",
            "Gemini 3.1 Pro (High)",
            "Gemini 3.5 Flash (Low)",
            "Gemini 3.5 Flash (Medium)",
            "Gemini 3.5 Flash (High)",
            "Claude Opus 4.6 (Thinking)",
            "Claude Sonnet 4.6 (Thinking)",
            "GPT-OSS 120B (Medium)",
        ])
    }
}
