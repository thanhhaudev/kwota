//
//  KwotaTestCaseGuardTests.swift
//  KwotaTests
//
//  Self-test that proves URLProtocolNetGuard catches real-network
//  attempts inside a KwotaTestCase. If this test ever stops failing
//  the way it expects, the guard is broken — fix the guard, not this
//  test.
//

import XCTest
@testable import Kwota

@MainActor
final class KwotaTestCaseGuardTests: KwotaTestCase {

    /// A real HTTP request inside a KwotaTestCase must throw — proving
    /// the guard intercepts before the request reaches the network.
    /// The guard itself emits an XCTFail when it fires (so unintentional
    /// leaks in real tests turn red); we mark that expected here.
    func test_realNetworkRequestThrowsInsideGuard() async {
        XCTExpectFailure("URLProtocolNetGuard fires XCTFail when it blocks a request") { issue in
            issue.compactDescription.contains("URLProtocolNetGuard")
        }
        let url = URL(string: "https://example.com/")!
        do {
            _ = try await URLSession.shared.data(from: url)
            XCTFail("Expected URLProtocolNetGuard to block real network request")
        } catch {
            // Pass — any error reaching here means the guard fired.
            XCTAssertTrue(error is URLError, "Expected URLError, got \(type(of: error))")
        }
    }

    /// `file://` URLs are allowed (tests legitimately read from temp
    /// dirs via FileManager / URLSession on local files in a few places).
    func test_fileURLsAreAllowed() throws {
        let tmp = tempDir.file("hello.txt")
        try "hi".data(using: .utf8)!.write(to: tmp)
        let data = try Data(contentsOf: tmp)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hi")
    }
}
