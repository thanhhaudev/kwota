import XCTest
@testable import Kwota

final class ShortcutsTabsRuntimeTests: XCTestCase {
    func test_nextTab_wrapsAcrossVisibleTabs() {
        XCTAssertEqual(
            PopupTabNavigator.nextTab(from: .cache, in: [.usage, .awake, .cache]),
            .usage
        )
    }

    func test_previousTab_wrapsAcrossVisibleTabs() {
        XCTAssertEqual(
            PopupTabNavigator.previousTab(from: .usage, in: [.usage, .cache]),
            .cache
        )
    }

    func test_nextTab_returnsNilWhenOnlyOneVisibleTab() {
        XCTAssertNil(PopupTabNavigator.nextTab(from: .usage, in: [.usage]))
    }

    func test_previousTab_fallsBackToLastWhenSelectionMissing() {
        XCTAssertEqual(
            PopupTabNavigator.previousTab(from: .awake, in: [.usage, .cache]),
            .cache
        )
    }
}
