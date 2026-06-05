import XCTest
@testable import Kwota

final class MenuBarStylePreviewTileTests: XCTestCase {
    func test_isSelected_when_tile_style_matches() {
        let tile = MenuBarStylePreviewTile.SelectionState(
            tile: .original, current: .original)
        XCTAssertTrue(tile.isSelected)
    }

    func test_not_selected_when_styles_differ() {
        let tile = MenuBarStylePreviewTile.SelectionState(
            tile: .original, current: .percentRing)
        XCTAssertFalse(tile.isSelected)
    }
}
