import XCTest
@testable import Kwota

final class PopoverTabVisibilityTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PopoverTabVisibilityTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_visibleTabs_defaultsToUsageAwakeCache() {
        let visibility = PopoverTabVisibility(defaults: defaults)

        XCTAssertEqual(visibility.visibleTabs, [.usage, .awake, .cache])
    }

    func test_visibleTabs_omitsHiddenTabs() {
        defaults.set(false, forKey: "display.popover.showAwake")
        let visibility = PopoverTabVisibility(defaults: defaults)

        XCTAssertEqual(visibility.visibleTabs, [.usage, .cache])
        XCTAssertFalse(visibility.isVisible(.awake))
        XCTAssertTrue(visibility.isVisible(.usage))
    }
}
