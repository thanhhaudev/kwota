import XCTest
import AppKit
@testable import Kwota

final class HotKeyFormatterTests: XCTestCase {
    private func def(_ keyCode: UInt16, _ mods: NSEvent.ModifierFlags) -> HotKeyDefinition {
        HotKeyDefinition(keyCode: keyCode, rawModifiers: mods.rawValue)
    }

    func test_letter_key_with_command_option() {
        // K = keyCode 40, ⌥⌘K
        XCTAssertEqual(HotKeyFormatter.string(for: def(40, [.command, .option])), "⌥⌘K")
    }

    func test_modifiers_render_in_canonical_order() {
        // Canonical order: ⌃⌥⇧⌘ (control, option, shift, command)
        XCTAssertEqual(
            HotKeyFormatter.string(for: def(40, [.command, .shift, .option, .control])),
            "⌃⌥⇧⌘K"
        )
    }

    func test_command_only() {
        XCTAssertEqual(HotKeyFormatter.string(for: def(40, .command)), "⌘K")
    }

    func test_function_key() {
        // F1 = keyCode 122
        XCTAssertEqual(HotKeyFormatter.string(for: def(122, .command)), "⌘F1")
    }

    func test_arrow_key() {
        // Up arrow = keyCode 126
        XCTAssertEqual(HotKeyFormatter.string(for: def(126, .command)), "⌘↑")
    }

    func test_digit() {
        // 1 = keyCode 18
        XCTAssertEqual(HotKeyFormatter.string(for: def(18, .command)), "⌘1")
    }

    func test_space() {
        // Space = keyCode 49
        XCTAssertEqual(HotKeyFormatter.string(for: def(49, [.command, .option])), "⌥⌘Space")
    }

    func test_unknown_key_falls_back_to_keycode_label() {
        // 200 is not in the map; expect a non-empty fallback (don't crash).
        let s = HotKeyFormatter.string(for: def(200, .command))
        XCTAssertTrue(s.hasPrefix("⌘"))
        XCTAssertFalse(s == "⌘", "must include some label after the modifier")
    }
}
