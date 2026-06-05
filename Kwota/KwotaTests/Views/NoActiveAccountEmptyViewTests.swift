import XCTest
@testable import Kwota

final class NoActiveAccountEmptyViewTests: XCTestCase {
    func test_join_empty_isEmptyString() {
        XCTAssertEqual(NoActiveAccountEmptyView.joinedNames([]), "")
    }

    func test_join_single() {
        XCTAssertEqual(NoActiveAccountEmptyView.joinedNames(["Claude"]), "Claude")
    }

    func test_join_two_usesOr() {
        XCTAssertEqual(NoActiveAccountEmptyView.joinedNames(["Claude", "Codex"]),
                       "Claude or Codex")
    }

    func test_join_three_usesOxfordOr() {
        XCTAssertEqual(
            NoActiveAccountEmptyView.joinedNames(["Claude", "Codex", "Antigravity"]),
            "Claude, Codex, or Antigravity")
    }
}
