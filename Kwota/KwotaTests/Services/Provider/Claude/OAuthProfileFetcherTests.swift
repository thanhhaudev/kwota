//
//  OAuthProfileFetcherTests.swift
//  KwotaTests

import XCTest
@testable import Kwota

@MainActor
final class OAuthProfileFetcherTests: XCTestCase {

    private let cliCred = Credential.cliToken(
        accessToken: "tok-abc",
        refreshToken: "r",
        expiresAt: .distantFuture
    )

    // MARK: - happy path

    func test_fetch_200_withRateLimitTier_returnsParsedPlan() async throws {
        let json = #"""
        {
          "account": {
            "uuid": "acc-1",
            "full_name": "Hau",
            "display_name": "Hau",
            "email": "h@x.com",
            "has_claude_max": true,
            "has_claude_pro": false,
            "created_at": "2026-04-23T10:56:18.505817Z"
          },
          "organization": {
            "uuid": "org-1",
            "name": "Org",
            "organization_type": "claude_max",
            "billing_type": "stripe_subscription",
            "rate_limit_tier": "default_claude_max_20x",
            "seat_tier": null,
            "has_extra_usage_enabled": false,
            "subscription_status": "active",
            "subscription_created_at": "2026-05-20T02:39:38.335764Z"
          },
          "application": {"uuid": "app-1", "name": "Claude Code", "slug": "claude-code"}
        }
        """#.data(using: .utf8)!
        let fetcher = OAuthProfileFetcher(transport: { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://x/")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (json, resp)
        })
        let r = try await fetcher.fetch(credential: cliCred)
        XCTAssertEqual(r.planLabel, "Max 20x")
        XCTAssertEqual(r.orgUuid, "org-1")
        XCTAssertEqual(r.email, "h@x.com")
        XCTAssertEqual(r.displayName, "Hau")
        XCTAssertEqual(r.subscriptionActive, true)
        XCTAssertEqual(r.hasExtraUsage, false)
        XCTAssertNotNil(r.subscriptionCreatedAt)
    }

    func test_fetch_200_withNullRateLimitTier_returnsNilPlan() async throws {
        let json = #"""
        {
          "account": {"uuid":"a","email":"x@y.com","has_claude_max":false,"has_claude_pro":true},
          "organization": {
            "uuid":"org-1",
            "rate_limit_tier": null,
            "seat_tier": null,
            "organization_type": null,
            "subscription_status": "active",
            "has_extra_usage_enabled": false
          }
        }
        """#.data(using: .utf8)!
        let fetcher = OAuthProfileFetcher(transport: { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://x/")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (json, resp)
        })
        let r = try await fetcher.fetch(credential: cliCred)
        XCTAssertNil(r.planLabel, "null rate_limit_tier + null seat_tier + null orgType → no label")
        XCTAssertEqual(r.orgUuid, "org-1")
    }

    func test_fetch_200_teamPremium() async throws {
        let json = #"""
        {
          "account": {"uuid":"a","email":"t@y.com"},
          "organization": {
            "uuid":"org-2",
            "rate_limit_tier":"default_claude_team_premium",
            "seat_tier": null,
            "subscription_status": "active",
            "has_extra_usage_enabled": true
          }
        }
        """#.data(using: .utf8)!
        let fetcher = OAuthProfileFetcher(transport: { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://x/")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (json, resp)
        })
        let r = try await fetcher.fetch(credential: cliCred)
        XCTAssertEqual(r.planLabel, "Team Premium")
        XCTAssertEqual(r.hasExtraUsage, true)
    }

    func test_fetch_200_fallsBackToSeatTier_whenRateLimitTierAbsent() async throws {
        // Defense in depth: profile API drops rate_limit_tier but still has
        // a usable seat_tier (e.g. a Team account on a CLI build that
        // populates seat_tier). Fetcher should still resolve a label.
        let json = #"""
        {
          "account":{"uuid":"a","email":"t@y.com"},
          "organization":{
            "uuid":"org-3",
            "rate_limit_tier": null,
            "seat_tier": "team_premium",
            "organization_type": "claude_team",
            "subscription_status": "active",
            "has_extra_usage_enabled": false
          }
        }
        """#.data(using: .utf8)!
        let fetcher = OAuthProfileFetcher(transport: { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://x/")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (json, resp)
        })
        let r = try await fetcher.fetch(credential: cliCred)
        XCTAssertEqual(r.planLabel, "Team Premium")
    }

    // MARK: - error path

    func test_fetch_401_throwsUnauthorized() async {
        let fetcher = OAuthProfileFetcher(transport: { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://x/")!,
                                       statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        })
        do {
            _ = try await fetcher.fetch(credential: cliCred)
            XCTFail("expected unauthorized")
        } catch ClaudeAPIClient.APIError.unauthorized {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_fetch_403_throwsUnauthorized() async {
        let fetcher = OAuthProfileFetcher(transport: { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://x/")!,
                                       statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        })
        do {
            _ = try await fetcher.fetch(credential: cliCred)
            XCTFail("expected unauthorized")
        } catch ClaudeAPIClient.APIError.unauthorized {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_fetch_429_throwsRateLimited_withRetryAfter() async {
        let fetcher = OAuthProfileFetcher(transport: { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://x/")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "45"]
            )!
            return (Data(), resp)
        })
        do {
            _ = try await fetcher.fetch(credential: cliCred)
            XCTFail("expected rateLimited")
        } catch ClaudeAPIClient.APIError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 45)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_fetch_500_throwsHTTP() async {
        let fetcher = OAuthProfileFetcher(transport: { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://x/")!,
                                       statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        })
        do {
            _ = try await fetcher.fetch(credential: cliCred)
            XCTFail("expected http")
        } catch ClaudeAPIClient.APIError.http(let status) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_fetch_decodeFailure_throwsDecode() async {
        let fetcher = OAuthProfileFetcher(transport: { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://x/")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("not json".utf8), resp)
        })
        do {
            _ = try await fetcher.fetch(credential: cliCred)
            XCTFail("expected decode error")
        } catch ClaudeAPIClient.APIError.decode {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_fetch_sessionKeyCredential_throwsUnauthorizedWithoutNetworkCall() async {
        let fetcher = OAuthProfileFetcher(transport: { _ in
            XCTFail("transport must NOT be called for sessionKey credentials")
            fatalError()
        })
        do {
            _ = try await fetcher.fetch(credential: .sessionKey(value: "sk"))
            XCTFail("expected unauthorized")
        } catch ClaudeAPIClient.APIError.unauthorized {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Extended Response fields (Task 2)

    func test_fetch_200_populatesNewResponseFields() async throws {
        let json = #"""
        {
          "account": {
            "uuid": "acc-1",
            "full_name": "Hau",
            "display_name": "Hau",
            "email": "h@x.com",
            "has_claude_max": true,
            "has_claude_pro": false,
            "created_at": "2026-04-23T10:56:18.505817Z"
          },
          "organization": {
            "uuid": "org-1",
            "name": "Hau's Org",
            "organization_type": "claude_max",
            "billing_type": "stripe_subscription",
            "rate_limit_tier": "default_claude_max_20x",
            "seat_tier": null,
            "has_extra_usage_enabled": false,
            "subscription_status": "active",
            "subscription_created_at": "2026-05-20T02:39:38.335764Z"
          }
        }
        """#.data(using: .utf8)!
        let fetcher = OAuthProfileFetcher(transport: { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://x/")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (json, resp)
        })
        let r = try await fetcher.fetch(credential: cliCred)
        XCTAssertEqual(r.accountUuid, "acc-1")
        XCTAssertEqual(r.organizationName, "Hau's Org")
        XCTAssertEqual(r.subscriptionStatus, "active")
        XCTAssertEqual(r.billingType, "stripe_subscription")
        XCTAssertNotNil(r.accountCreatedAt)
    }

    func test_fetch_200_nullableNewFields_handled() async throws {
        let json = #"""
        {
          "account": {"uuid": null, "email": "h@x.com", "created_at": null},
          "organization": {
            "uuid": "org-1",
            "name": null,
            "rate_limit_tier": null,
            "seat_tier": null,
            "organization_type": null,
            "subscription_status": null,
            "billing_type": null,
            "has_extra_usage_enabled": false
          }
        }
        """#.data(using: .utf8)!
        let fetcher = OAuthProfileFetcher(transport: { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://x/")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (json, resp)
        })
        let r = try await fetcher.fetch(credential: cliCred)
        XCTAssertNil(r.accountUuid)
        XCTAssertNil(r.organizationName)
        XCTAssertNil(r.subscriptionStatus)
        XCTAssertNil(r.billingType)
        XCTAssertNil(r.accountCreatedAt)
    }

    // MARK: - nil / missing has_extra_usage_enabled

    func test_fetch_200_missingHasExtraUsage_preservesNil() async throws {
        // Regression: a payload that omits `has_extra_usage_enabled`
        // (or makes it null) must NOT be coerced to `false` by the decoder.
        // The downstream ProfileStore.apply rule treats nil as "no info"
        // and skips the write; coercing to false would silently flip a
        // stored `true` on every probe.
        let json = #"""
        {
          "account": {"uuid":"a","email":"x@y.com"},
          "organization": {
            "uuid":"org-1",
            "rate_limit_tier": "default_claude_max_20x",
            "subscription_status": "active"
          }
        }
        """#.data(using: .utf8)!
        let fetcher = OAuthProfileFetcher(transport: { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://x/")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (json, resp)
        })
        let r = try await fetcher.fetch(credential: cliCred)
        XCTAssertNil(r.hasExtraUsage,
                     "missing has_extra_usage_enabled must decode to nil, not false")
    }

    func test_fetch_200_nullHasExtraUsage_preservesNil() async throws {
        let json = #"""
        {
          "account": {"uuid":"a","email":"x@y.com"},
          "organization": {
            "uuid":"org-1",
            "has_extra_usage_enabled": null,
            "rate_limit_tier": "default_claude_max_20x"
          }
        }
        """#.data(using: .utf8)!
        let fetcher = OAuthProfileFetcher(transport: { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://x/")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (json, resp)
        })
        let r = try await fetcher.fetch(credential: cliCred)
        XCTAssertNil(r.hasExtraUsage)
    }

    // MARK: - request shape

    func test_request_setsCorrectHeadersAndURLAndMethod() async throws {
        let json = #"{"account":{"uuid":"a"},"organization":{"uuid":"o"}}"#.data(using: .utf8)!
        let captured = CapturedRequest()
        let fetcher = OAuthProfileFetcher(transport: { req in
            await captured.store(req)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (json, resp)
        })
        _ = try await fetcher.fetch(credential: cliCred)
        let req = await captured.value!
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/api/oauth/profile")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-abc")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertTrue((req.value(forHTTPHeaderField: "User-Agent") ?? "").hasPrefix("Kwota/"))
        // Anthropic developer host — claude.ai headers must NOT be sent.
        XCTAssertNil(req.value(forHTTPHeaderField: "Origin"))
        XCTAssertNil(req.value(forHTTPHeaderField: "Referer"))
    }
}

/// Concurrency-safe holder for a request captured inside the transport
/// closure (the closure is `@Sendable` so it can't touch `self` directly).
private actor CapturedRequest {
    var value: URLRequest?
    func store(_ req: URLRequest) { value = req }
}
