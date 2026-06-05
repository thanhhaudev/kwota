import XCTest
@testable import Kwota

final class SettingsWindowPresenterDockModeTests: XCTestCase {
    func test_shouldSwapForSettings_only_in_auto() {
        XCTAssertTrue(SettingsWindowPresenter.shouldSwapForSettings(mode: .auto))
        XCTAssertFalse(SettingsWindowPresenter.shouldSwapForSettings(mode: .alwaysHide))
        XCTAssertFalse(SettingsWindowPresenter.shouldSwapForSettings(mode: .alwaysShow))
    }
}
