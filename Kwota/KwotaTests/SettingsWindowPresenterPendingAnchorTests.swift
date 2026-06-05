// SettingsWindowPresenterPendingAnchorTests.swift
// KwotaTests

import XCTest
@testable import Kwota

@MainActor
final class SettingsWindowPresenterPendingAnchorTests: XCTestCase {
    func test_pending_anchor_id_defaults_to_nil() {
        let presenter = SettingsWindowPresenter.shared
        let saved = presenter.pendingAnchorId
        presenter.pendingAnchorId = nil
        XCTAssertNil(presenter.pendingAnchorId)
        presenter.pendingAnchorId = saved
    }

    func test_pending_anchor_id_round_trips() {
        let presenter = SettingsWindowPresenter.shared
        let saved = presenter.pendingAnchorId
        presenter.pendingAnchorId = "display.menubar"
        XCTAssertEqual(presenter.pendingAnchorId, "display.menubar")
        presenter.pendingAnchorId = saved
    }
}
