//
//  AntigravityAPIClientTests.swift
//

import XCTest
@testable import Kwota

final class AntigravityAPIClientTests: XCTestCase {
    /// Minimal JSON body that decodes into AntigravityUsageSnapshot with
    /// just an email present. Keeps tests focused on transport behavior
    /// rather than snapshot decoding (covered by AntigravityUsageSnapshotTests).
    private let sampleJSON = #"{"userStatus":{"email":"u@b.com"}}"#

    /// Builds a transport stub that returns the given status + body for any
    /// request. Captures the last URLRequest into `captured` so tests can
    /// inspect headers/body.
    private func stub(
        status: Int,
        body: String,
        captured: Captured? = nil
    ) -> ClaudeAPIClient.Transport {
        return { req in
            captured?.requests.append(req)
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (body.data(using: .utf8) ?? Data(), resp)
        }
    }

    /// Mutable capture box (reference type so the @escaping closure can
    /// write through). Avoids @MainActor / actor ceremony for tests.
    private final class Captured: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    // MARK: - 1. HTTP succeeds → decoded snapshot

    func test_fetchSnapshot_httpSucceeds_decodes() async throws {
        let captured = Captured()
        let client = AntigravityAPIClient(
            transport: stub(status: 200, body: sampleJSON, captured: captured)
        )
        let snap = try await client.fetchSnapshot(port: 49839, csrfToken: "tok")
        XCTAssertEqual(snap.email, "u@b.com")
        // First (and only) request should be HTTP, not HTTPS.
        XCTAssertEqual(captured.requests.first?.url?.scheme, "http")
        XCTAssertEqual(captured.requests.first?.url?.host, "127.0.0.1")
        XCTAssertEqual(captured.requests.first?.url?.port, 49839)
        XCTAssertEqual(captured.requests.count, 1)
    }

    // MARK: - 2. HTTP fails → HTTPS fallback

    func test_fetchSnapshot_httpFails_httpsFallbackUsed() async throws {
        let captured = Captured()
        // First call (HTTP) → non-200; second call (HTTPS) → 200.
        var callIndex = 0
        let transport: ClaudeAPIClient.Transport = { [sampleJSON] req in
            captured.requests.append(req)
            defer { callIndex += 1 }
            if callIndex == 0 {
                // HTTP returns 500
                let resp = HTTPURLResponse(
                    url: req.url!, statusCode: 500,
                    httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            } else {
                let resp = HTTPURLResponse(
                    url: req.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!
                return (sampleJSON.data(using: .utf8)!, resp)
            }
        }
        let client = AntigravityAPIClient(transport: transport)
        let snap = try await client.fetchSnapshot(port: 49838, csrfToken: "tok")
        XCTAssertEqual(snap.email, "u@b.com")
        XCTAssertEqual(captured.requests.count, 2)
        XCTAssertEqual(captured.requests[0].url?.scheme, "http")
        XCTAssertEqual(captured.requests[1].url?.scheme, "https")
        XCTAssertEqual(captured.requests[1].url?.port, 49838)
    }

    // MARK: - 3. Both schemes fail → .transient

    func test_fetchSnapshot_bothSchemesFail_throwsTransient() async {
        struct ConnRefused: Error {}
        let transport: ClaudeAPIClient.Transport = { _ in
            throw ConnRefused()
        }
        let client = AntigravityAPIClient(transport: transport)
        do {
            _ = try await client.fetchSnapshot(port: 49839, csrfToken: "tok")
            XCTFail("Expected .transient")
        } catch ClaudeAPIClient.APIError.transient {
            // pass
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - 4. 200 + malformed JSON → .decode

    func test_fetchSnapshot_200WithMalformedJSON_throwsDecode() async {
        let client = AntigravityAPIClient(
            transport: stub(status: 200, body: "not json")
        )
        do {
            _ = try await client.fetchSnapshot(port: 49839, csrfToken: "tok")
            XCTFail("Expected .decode")
        } catch ClaudeAPIClient.APIError.decode {
            // pass
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - 5. Correct headers + body

    func test_fetchSnapshot_sendsCorrectHeaders() async throws {
        let captured = Captured()
        let client = AntigravityAPIClient(
            transport: stub(status: 200, body: sampleJSON, captured: captured)
        )
        _ = try await client.fetchSnapshot(port: 49839, csrfToken: "the-csrf")

        let req = try XCTUnwrap(captured.requests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "Connect-Protocol-Version"),
            "1"
        )
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "X-Codeium-Csrf-Token"),
            "the-csrf"
        )
        let body = try XCTUnwrap(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let metadata = json?["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["ideName"] as? String, "antigravity")
        XCTAssertEqual(metadata?["extensionName"] as? String, "antigravity")
        XCTAssertEqual(metadata?["locale"] as? String, "en")

        // Path matches the Connect-RPC method route.
        XCTAssertEqual(
            req.url?.path,
            "/exa.language_server_pb.LanguageServerService/GetUserStatus"
        )
    }

    // MARK: - 6. fetchedAt stamped from `now`

    func test_fetchSnapshot_stampsFetchedAt() async throws {
        let fixed = Date(timeIntervalSince1970: 1234)
        let client = AntigravityAPIClient(
            transport: stub(status: 200, body: sampleJSON),
            now: { fixed }
        )
        let snap = try await client.fetchSnapshot(port: 49839, csrfToken: "tok")
        XCTAssertEqual(snap.fetchedAt, fixed)
    }

    // MARK: - Quota summary

    private let quotaJSON = """
    {"response":{"groups":[
      {"displayName":"Gemini Models","buckets":[
        {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.5,"resetTime":"2026-06-13T15:40:07Z"}]}]}}
    """

    func test_fetchQuotaSummary_httpSucceeds_decodes() async throws {
        let captured = Captured()
        let client = AntigravityAPIClient(
            transport: stub(status: 200, body: quotaJSON, captured: captured))
        let q = try await client.fetchQuotaSummary(port: 49839, csrfToken: "tok")
        XCTAssertEqual(q.groups.count, 1)
        XCTAssertEqual(q.groups.first?.fiveHour?.utilization ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(captured.requests.first?.url?.scheme, "http")
        XCTAssertEqual(
            captured.requests.first?.url?.path,
            "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")
        XCTAssertEqual(captured.requests.first?.value(forHTTPHeaderField: "X-Codeium-Csrf-Token"), "tok")
    }

    func test_fetchQuotaSummary_httpFails_httpsFallback() async throws {
        var i = 0
        let transport: ClaudeAPIClient.Transport = { [quotaJSON] req in
            defer { i += 1 }
            let status = (i == 0) ? 500 : 200
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (status == 200 ? Data(quotaJSON.utf8) : Data(), resp)
        }
        let q = try await AntigravityAPIClient(transport: transport)
            .fetchQuotaSummary(port: 1, csrfToken: "t")
        XCTAssertEqual(q.groups.count, 1)
    }

    func test_fetchQuotaSummary_allFail_throwsTransient() async {
        let transport: ClaudeAPIClient.Transport = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        do {
            _ = try await AntigravityAPIClient(transport: transport)
                .fetchQuotaSummary(port: 1, csrfToken: "t")
            XCTFail("expected throw")
        } catch let e as ClaudeAPIClient.APIError {
            XCTAssertEqual(e, .transient)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test_fetchQuotaSummary_200BadJSON_throwsDecode() async {
        let transport: ClaudeAPIClient.Transport = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{not json".utf8), resp)
        }
        do {
            _ = try await AntigravityAPIClient(transport: transport)
                .fetchQuotaSummary(port: 1, csrfToken: "t")
            XCTFail("expected throw")
        } catch let e as ClaudeAPIClient.APIError {
            if case .decode = e {} else { XCTFail("expected .decode, got \(e)") }
        } catch { XCTFail("wrong error: \(error)") }
    }
}
