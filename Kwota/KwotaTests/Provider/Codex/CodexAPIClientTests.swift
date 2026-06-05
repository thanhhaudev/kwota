//
//  CodexAPIClientTests.swift
//

import XCTest
@testable import Kwota

final class CodexAPIClientTests: XCTestCase {
    private func makeClient(status: Int, body: String = "", retryAfter: String? = nil)
        -> CodexAPIClient
    {
        let transport: ClaudeAPIClient.Transport = { req in
            var headers: [String: String] = [:]
            if let retryAfter { headers["Retry-After"] = retryAfter }
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
            return (body.data(using: .utf8) ?? Data(), resp)
        }
        return CodexAPIClient(transport: transport, now: { Date() })
    }

    private let credential = Credential.cliToken(
        accessToken: "acc",
        refreshToken: "r",
        expiresAt: .distantFuture
    )

    func test_fetchSnapshot_decodes200_fullResponse() async throws {
        let body = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window":   { "used_percent": 27, "limit_window_seconds": 18000,  "reset_at": "2026-05-25T18:22:00Z" },
            "secondary_window": { "used_percent": 46, "limit_window_seconds": 604800, "reset_at": "2026-05-29T09:15:00Z" }
          },
          "code_review_rate_limit": { "used_percent": 9, "limit_window_seconds": 604800, "reset_at": "2026-05-31T14:30:00Z" }
        }
        """
        let client = makeClient(status: 200, body: body)
        let snap = try await client.fetchSnapshot(credential: credential)
        XCTAssertEqual(snap.planType, "plus")
        XCTAssertEqual(snap.rateLimit?.primaryWindow?.usedPercent, 27)
        XCTAssertEqual(snap.codeReviewRateLimit?.usedPercent, 9)
    }

    func test_fetchSnapshot_throws401() async {
        let client = makeClient(status: 401)
        do {
            _ = try await client.fetchSnapshot(credential: credential)
            XCTFail("Expected unauthorized")
        } catch ClaudeAPIClient.APIError.unauthorized {
            // pass
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_fetchSnapshot_throws429WithRetryAfter() async {
        let client = makeClient(status: 429, retryAfter: "60")
        do {
            _ = try await client.fetchSnapshot(credential: credential)
            XCTFail("Expected rateLimited")
        } catch ClaudeAPIClient.APIError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 60)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_fetchSnapshot_throws429WithoutRetryAfter() async {
        let client = makeClient(status: 429)
        do {
            _ = try await client.fetchSnapshot(credential: credential)
            XCTFail("Expected rateLimited")
        } catch ClaudeAPIClient.APIError.rateLimited(let retryAfter) {
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_fetchSnapshot_throws5xx() async {
        let client = makeClient(status: 503)
        do {
            _ = try await client.fetchSnapshot(credential: credential)
            XCTFail("Expected http error")
        } catch ClaudeAPIClient.APIError.http(let status) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_fetchSnapshot_rejectsNonCLITokenCredential() async {
        let client = makeClient(status: 200)
        do {
            _ = try await client.fetchSnapshot(credential: .sessionKey(value: "x"))
            XCTFail("Expected unauthorized")
        } catch ClaudeAPIClient.APIError.unauthorized {
            // pass
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}
