//
//  HotKeyRecorderViewStateTests.swift
//  KwotaTests
//

import XCTest
import AppKit
@testable import Kwota

final class HotKeyRecorderViewStateTests: XCTestCase {
    private let sample = HotKeyDefinition(
        keyCode: 40, // K
        rawModifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
    )

    // MARK: - resolve

    func test_resolve_returns_recording_when_isRecording_true_regardless_of_definition() {
        XCTAssertEqual(
            RecorderVisualState.resolve(definition: nil, isRecording: true),
            .recording
        )
        XCTAssertEqual(
            RecorderVisualState.resolve(definition: sample, isRecording: true),
            .recording
        )
    }

    func test_resolve_returns_unset_when_definition_nil_and_not_recording() {
        XCTAssertEqual(
            RecorderVisualState.resolve(definition: nil, isRecording: false),
            .unset
        )
    }

    func test_resolve_returns_set_when_definition_present_and_not_recording() {
        XCTAssertEqual(
            RecorderVisualState.resolve(definition: sample, isRecording: false),
            .set(sample)
        )
    }

    // MARK: - displayString

    func test_displayString_unset_is_none() {
        XCTAssertEqual(RecorderVisualState.unset.displayString, "none")
    }

    func test_displayString_recording_is_placeholder() {
        XCTAssertEqual(RecorderVisualState.recording.displayString, "Type shortcut…")
    }

    func test_displayString_set_matches_HotKeyFormatter() {
        XCTAssertEqual(
            RecorderVisualState.set(sample).displayString,
            HotKeyFormatter.string(for: sample)
        )
    }
}
