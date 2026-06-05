import XCTest
@testable import Kwota

final class DockIconModeTests: XCTestCase {
    private let suiteName = "DockIconModeTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_default_is_auto_when_key_missing() {
        let store = DockIconModeStore(defaults: defaults)
        XCTAssertEqual(store.mode, .auto)
    }

    func test_round_trip_all_cases() {
        let store = DockIconModeStore(defaults: defaults)
        for mode in DockIconMode.allCases {
            store.mode = mode
            let other = DockIconModeStore(defaults: defaults)
            XCTAssertEqual(other.mode, mode, "round-trip failed for \(mode)")
        }
    }

    func test_unknown_raw_value_falls_back_to_auto() {
        defaults.set("not-a-mode", forKey: DockIconModeStore.key)
        let store = DockIconModeStore(defaults: defaults)
        XCTAssertEqual(store.mode, .auto)
    }
}
