import XCTest
@testable import Kwota

final class ProfileNavigatorTests: XCTestCase {
    private let a = Profile(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, name: "A", authMethod: .cliSync)
    private let b = Profile(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!, name: "B", authMethod: .cliSync)
    private let c = Profile(id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!, name: "C", authMethod: .cliSync)

    func test_next_wrapsFromEndToStart() {
        XCTAssertEqual(
            ProfileNavigator.nextProfileID(from: c.id, in: [a, b, c]),
            a.id
        )
    }

    func test_previous_wrapsFromStartToEnd() {
        XCTAssertEqual(
            ProfileNavigator.previousProfileID(from: a.id, in: [a, b, c]),
            c.id
        )
    }

    func test_next_fromNilStartsAtFirstProfile() {
        XCTAssertEqual(
            ProfileNavigator.nextProfileID(from: nil, in: [a, b, c]),
            a.id
        )
    }

    func test_previous_fromNilStartsAtLastProfile() {
        XCTAssertEqual(
            ProfileNavigator.previousProfileID(from: nil, in: [a, b, c]),
            c.id
        )
    }

    func test_singleProfile_returnsNil() {
        XCTAssertNil(ProfileNavigator.nextProfileID(from: a.id, in: [a]))
        XCTAssertNil(ProfileNavigator.previousProfileID(from: a.id, in: [a]))
    }
}
