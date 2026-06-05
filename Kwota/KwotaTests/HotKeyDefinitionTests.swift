import XCTest
import AppKit
@testable import Kwota

final class HotKeyDefinitionTests: XCTestCase {
    func test_init_normalizes_modifiers_to_device_independent_mask() {
        // Caps Lock bit is outside deviceIndependentFlagsMask; should be stripped.
        let raw = NSEvent.ModifierFlags([.command, .option, .capsLock]).rawValue
        let def = HotKeyDefinition(keyCode: 40, rawModifiers: raw)
        XCTAssertEqual(def.keyCode, 40)
        XCTAssertEqual(def.nsModifiers, [.command, .option])
    }

    func test_round_trip_json() throws {
        let def = HotKeyDefinition(keyCode: 12, rawModifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
        let data = try JSONEncoder().encode(def)
        let decoded = try JSONDecoder().decode(HotKeyDefinition.self, from: data)
        XCTAssertEqual(def, decoded)
    }

    func test_equatable() {
        let a = HotKeyDefinition(keyCode: 40, rawModifiers: NSEvent.ModifierFlags.command.rawValue)
        let b = HotKeyDefinition(keyCode: 40, rawModifiers: NSEvent.ModifierFlags.command.rawValue)
        let c = HotKeyDefinition(keyCode: 40, rawModifiers: NSEvent.ModifierFlags.option.rawValue)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func test_matches_normalized_keycode_and_modifiers() {
        let def = HotKeyDefinition(
            keyCode: 18,
            rawModifiers: NSEvent.ModifierFlags([.command, .option]).rawValue
        )

        XCTAssertTrue(
            def.matches(
                keyCode: 18,
                rawModifiers: NSEvent.ModifierFlags([.command, .option, .capsLock]).rawValue
            )
        )
        XCTAssertFalse(
            def.matches(
                keyCode: 18,
                rawModifiers: NSEvent.ModifierFlags.command.rawValue
            )
        )
        XCTAssertFalse(
            def.matches(
                keyCode: 19,
                rawModifiers: NSEvent.ModifierFlags([.command, .option]).rawValue
            )
        )
    }
}
