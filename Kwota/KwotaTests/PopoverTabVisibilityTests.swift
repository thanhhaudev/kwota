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

    func test_visibleTabs_defaultsToUsageStatsAwakeCache() {
        let visibility = PopoverTabVisibility(defaults: defaults)

        XCTAssertEqual(visibility.visibleTabs, [.usage, .stats, .awake, .cache])
    }

    func test_statsTab_isVisibleByDefault_andHideable() {
        let onByDefault = PopoverTabVisibility(defaults: defaults)
        XCTAssertTrue(onByDefault.isVisible(.stats))

        defaults.set(false, forKey: "display.popover.showStats")
        let hidden = PopoverTabVisibility(defaults: defaults)
        XCTAssertFalse(hidden.isVisible(.stats))
        XCTAssertEqual(hidden.visibleTabs, [.usage, .awake, .cache])
    }

    func test_visibleTabs_omitsHiddenTabs() {
        defaults.set(false, forKey: "display.popover.showAwake")
        let visibility = PopoverTabVisibility(defaults: defaults)

        XCTAssertEqual(visibility.visibleTabs, [.usage, .stats, .cache])
        XCTAssertFalse(visibility.isVisible(.awake))
        XCTAssertTrue(visibility.isVisible(.usage))
    }
}
