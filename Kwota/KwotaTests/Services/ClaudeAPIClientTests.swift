//
//  ClaudeAPIClientTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class ClaudeAPIClientTests: XCTestCase {
    func testUsageRequestSessionKeyVariant() throws {
        let req = ClaudeAPIClient.makeUsageRequest(
            orgId: "org-123",
            credential: .sessionKey(value: "sk-abc")
        )
        XCTAssertEqual(req.url?.absoluteString,
                       "https://claude.ai/api/organizations/org-123/usage")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Cookie"), "sessionKey=sk-abc")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func testUsageRequestCLITokenVariant() throws {
        let req = ClaudeAPIClient.makeUsageRequest(
            orgId: "org-123",
            credential: .cliToken(accessToken: "tok-x", refreshToken: "r", expiresAt: Date.distantFuture)
        )
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-x")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertNil(req.value(forHTTPHeaderField: "Cookie"))
    }

    func testOrganizationsRequestUsesSameAuthRules() throws {
        let req = ClaudeAPIClient.makeOrganizationsRequest(
            credential: .sessionKey(value: "sk-y")
        )
        XCTAssertEqual(req.url?.absoluteString, "https://claude.ai/api/organizations")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Cookie"), "sessionKey=sk-y")
    }

    func testUserAgentIsHonestKwotaIdentifier() throws {
        // Regression: UA must NOT spoof Mozilla/Safari. We identify as Kwota
        // openly so Anthropic can engage with us as a third-party client.
        let req = ClaudeAPIClient.makeUsageRequest(
            orgId: "o",
            credential: .sessionKey(value: "k")
        )
        let ua = req.value(forHTTPHeaderField: "User-Agent") ?? ""
        XCTAssertTrue(ua.hasPrefix("Kwota/"), "UA should start with Kwota/, got: \(ua)")
        XCTAssertFalse(ua.contains("Mozilla"), "UA must not impersonate a browser, got: \(ua)")
        XCTAssertFalse(ua.contains("AppleWebKit"), "UA must not impersonate a browser, got: \(ua)")
    }

    func testDecodeUsageResponseFromFixture() throws {
        let json = #"""
        {
          "five_hour":      {"utilization": 45,   "resets_at": "2026-04-28T18:00:00Z"},
          "seven_day":      {"utilization": 60,   "resets_at": "2026-05-02T00:00:00Z"},
          "seven_day_opus": {"utilization": 81,   "resets_at": "2026-05-02T00:00:00Z"},
          "seven_day_sonnet":{"utilization": 45,  "resets_at": "2026-05-02T00:00:00Z"}
        }
        """#
        let data = Data(json.utf8)
        let snapshot = try ClaudeAPIClient.decodeUsage(data: data, now: Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(snapshot.fiveHour.utilization, 45)
        XCTAssertEqual(snapshot.sevenDay.utilization, 60)
        XCTAssertEqual(snapshot.sevenDayOpus?.utilization, 81)
        XCTAssertEqual(snapshot.sevenDaySonnet?.utilization, 45)
        XCTAssertNil(snapshot.sevenDayOmelette,
                     "seven_day_omelette absent in fixture must decode to nil, not throw")
        XCTAssertEqual(snapshot.fetchedAt.timeIntervalSince1970, 1700000000)
    }

    func testDecodeUsageReadsSevenDayOmelette() throws {
        // Fixture mirrors the actual claude.ai response shape — Opus null,
        // Sonnet + Omelette populated, plus the other codename fields the API
        // returns null. Asserts:
        //   1. seven_day_omelette decodes to "Claude Design" bucket
        //   2. unknown codename keys (cowork, tangelo, etc) don't break decoding
        //   3. nil-valued sibling fields stay nil
        let json = #"""
        {
          "five_hour":           {"utilization": 78, "resets_at": "2026-05-01T17:30:00Z"},
          "seven_day":           {"utilization": 81, "resets_at": "2026-05-05T11:59:59Z"},
          "seven_day_oauth_apps": null,
          "seven_day_opus":       null,
          "seven_day_sonnet":    {"utilization": 13, "resets_at": "2026-05-05T11:59:59Z"},
          "seven_day_cowork":     null,
          "seven_day_omelette":  {"utilization": 8,  "resets_at": "2026-05-05T12:00:00Z"},
          "tangelo":              null,
          "iguana_necktie":       null,
          "omelette_promotional": null,
          "extra_usage": {"is_enabled": false, "monthly_limit": null,
                          "used_credits": null, "utilization": null, "currency": null}
        }
        """#
        let data = Data(json.utf8)
        let snapshot = try ClaudeAPIClient.decodeUsage(data: data, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(snapshot.sevenDayOmelette?.utilization, 8)
        XCTAssertNotNil(snapshot.sevenDayOmelette?.resetsAt)
        XCTAssertEqual(snapshot.sevenDaySonnet?.utilization, 13)
        XCTAssertNil(snapshot.sevenDayOpus,
                     "explicit null for seven_day_opus must round-trip as nil")
    }

    func testDecodeUsageReadsFableFromScopedWeeklyLimits() throws {
        // Fixture mirrors the 2026-07 live response: every seven_day_* per-model
        // key is null (the old "Sonnet only" source dried up) and the per-model
        // quota moved into the new `limits` array as a weekly_scoped entry whose
        // scope names the model ("Fable"). Asserts:
        //   1. sevenDayFable is sourced from limits[kind=weekly_scoped, model=Fable]
        //   2. non-scoped limits entries (session, weekly_all) are ignored
        //   3. null seven_day_* siblings still decode to nil
        let json = #"""
        {
          "five_hour":           {"utilization": 31, "resets_at": "2026-07-02T09:29:59.989898+00:00"},
          "seven_day":           {"utilization": 13, "resets_at": "2026-07-03T22:59:59.989924+00:00"},
          "seven_day_opus":       null,
          "seven_day_sonnet":     null,
          "seven_day_omelette":   null,
          "tangelo":              null,
          "limits": [
            {"kind": "session",       "group": "session", "percent": 31, "severity": "normal",
             "resets_at": "2026-07-02T09:29:59.989898+00:00", "scope": null, "is_active": true},
            {"kind": "weekly_all",    "group": "weekly",  "percent": 13, "severity": "normal",
             "resets_at": "2026-07-03T22:59:59.989924+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly",  "percent": 11, "severity": "normal",
             "resets_at": "2026-07-03T23:00:00.990218+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
             "is_active": false}
          ]
        }
        """#
        let snapshot = try ClaudeAPIClient.decodeUsage(
            data: Data(json.utf8),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(snapshot.sevenDayFable?.utilization, 11)
        XCTAssertNotNil(snapshot.sevenDayFable?.resetsAt)
        XCTAssertNil(snapshot.sevenDaySonnet)
        XCTAssertNil(snapshot.sevenDayOmelette)
    }

    func testDecodeUsageIgnoresScopedLimitsForOtherModels() throws {
        // A weekly_scoped entry for some other model must not populate the
        // Fable bucket — matching is on scope.model.display_name.
        let json = #"""
        {
          "five_hour": {"utilization": 10, "resets_at": "2026-07-02T09:00:00Z"},
          "seven_day": {"utilization": 20, "resets_at": "2026-07-03T22:00:00Z"},
          "limits": [
            {"kind": "weekly_scoped", "group": "weekly", "percent": 40,
             "resets_at": "2026-07-03T23:00:00Z",
             "scope": {"model": {"id": null, "display_name": "Opus"}, "surface": null}}
          ]
        }
        """#
        let snapshot = try ClaudeAPIClient.decodeUsage(
            data: Data(json.utf8),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertNil(snapshot.sevenDayFable)
    }

    func testUsageSnapshotRoundTripsFableThroughCachedEncoding() throws {
        // Cached snapshots persist via UsageSnapshot's own Codable encode
        // (profiles.json), which has no `limits` array — sevenDayFable must
        // round-trip through its direct seven_day_fable key.
        let original = UsageSnapshot(
            fiveHour: UsageBucket(utilization: 31, resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
            sevenDay: UsageBucket(utilization: 13, resetsAt: Date(timeIntervalSince1970: 1_800_100_000)),
            sevenDayFable: UsageBucket(utilization: 11, resetsAt: Date(timeIntervalSince1970: 1_800_200_000)),
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(decoded.sevenDayFable?.utilization, 11)
    }

    func testDecodeUsageThrowsOnMalformed() {
        XCTAssertThrowsError(try ClaudeAPIClient.decodeUsage(data: Data("oops".utf8), now: Date()))
    }

    // MARK: - fetchSnapshotViaOAuthUsage (CLI primary path)

    func testFetchSnapshotViaOAuthUsageDecodesFullPerModelShape() async throws {
        // Real Anthropic shape captured from `claude --debug api`:
        // api.anthropic.com/api/oauth/usage returns the same JSON as the
        // sessionKey claude.ai/api/usage endpoint, including per-model
        // breakdown. CLI profiles now unlock Sonnet only / Claude Design
        // rows without needing 1-token Messages API probes.
        let json = #"""
        {
          "five_hour":         {"utilization": 62, "resets_at": "2026-05-02T05:50:00Z"},
          "seven_day":         {"utilization": 88, "resets_at": "2026-05-05T12:00:00Z"},
          "seven_day_sonnet":  {"utilization": 13, "resets_at": "2026-05-05T12:00:00Z"},
          "seven_day_omelette":{"utilization": 8,  "resets_at": "2026-05-05T12:00:01Z"},
          "extra_usage": {"is_enabled": false, "monthly_limit": null,
                          "used_credits": null, "utilization": null}
        }
        """#.data(using: .utf8)!
        let client = ClaudeAPIClient(
            transport: { req in
                XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
                XCTAssertEqual(req.httpMethod, "GET")
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
                XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (json, resp)
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let result = try await client.fetchSnapshotViaOAuthUsage(
            credential: .cliToken(accessToken: "tok", refreshToken: "r", expiresAt: .distantFuture)
        )
        XCTAssertEqual(result.snapshot.fiveHour.utilization, 62)
        XCTAssertEqual(result.snapshot.sevenDay.utilization, 88)
        XCTAssertEqual(result.snapshot.sevenDaySonnet?.utilization, 13)
        XCTAssertEqual(result.snapshot.sevenDayOmelette?.utilization, 8)
        XCTAssertEqual(result.snapshot.fetchedAt.timeIntervalSince1970, 1_700_000_000)
        XCTAssertNil(result.retryAfter)
    }

    func testFetchSnapshotViaOAuthUsageRejectsSessionKeyCredential() async {
        // The endpoint uses Bearer + oauth-2025-04-20 beta header — a cookie
        // sessionKey credential won't even reach the wire.
        let client = ClaudeAPIClient(transport: { _ in
            XCTFail("must short-circuit before transport when credential is sessionKey")
            fatalError()
        })
        do {
            _ = try await client.fetchSnapshotViaOAuthUsage(credential: .sessionKey(value: "sk"))
            XCTFail("expected unauthorized")
        } catch ClaudeAPIClient.APIError.unauthorized {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testFetchSnapshotViaOAuthUsageThrowsUnauthorizedOn401() async {
        let client = ClaudeAPIClient(transport: { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        })
        do {
            _ = try await client.fetchSnapshotViaOAuthUsage(
                credential: .cliToken(accessToken: "tok", refreshToken: "r", expiresAt: .distantFuture)
            )
            XCTFail("expected unauthorized")
        } catch ClaudeAPIClient.APIError.unauthorized {
            // ok — caller will trigger forceRefresh + retry
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testFetchSnapshotViaOAuthUsageThrowsRateLimitedOn429() async {
        let client = ClaudeAPIClient(transport: { req in
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "30"]
            )!
            return (Data(), resp)
        })
        do {
            _ = try await client.fetchSnapshotViaOAuthUsage(
                credential: .cliToken(accessToken: "tok", refreshToken: "r", expiresAt: .distantFuture)
            )
            XCTFail("expected rateLimited")
        } catch ClaudeAPIClient.APIError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 30,
                           "Retry-After must surface so the coordinator can back off")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testFetchSnapshotViaOAuthUsageThrowsHTTPOn5xx() async {
        let client = ClaudeAPIClient(transport: { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        })
        do {
            _ = try await client.fetchSnapshotViaOAuthUsage(
                credential: .cliToken(accessToken: "tok", refreshToken: "r", expiresAt: .distantFuture)
            )
            XCTFail("expected http(503)")
        } catch ClaudeAPIClient.APIError.http(let status) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testFetchSnapshotViaOAuthUsageDoesNotSendClaudeAiHeaders() async throws {
        // Sanity: this endpoint is api.anthropic.com (developer host).
        // Sending Origin/Referer for claude.ai would be incorrect.
        let json = #"""
        {"five_hour":{"utilization":0,"resets_at":"2026-05-02T05:50:00Z"},
         "seven_day":{"utilization":0,"resets_at":"2026-05-05T12:00:00Z"}}
        """#.data(using: .utf8)!
        var sawOrigin: String?
        var sawReferer: String?
        let client = ClaudeAPIClient(transport: { req in
            sawOrigin = req.value(forHTTPHeaderField: "Origin")
            sawReferer = req.value(forHTTPHeaderField: "Referer")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (json, resp)
        })
        _ = try await client.fetchSnapshotViaOAuthUsage(
            credential: .cliToken(accessToken: "tok", refreshToken: "r", expiresAt: .distantFuture)
        )
        XCTAssertNil(sawOrigin, "Origin must not be set for api.anthropic.com")
        XCTAssertNil(sawReferer, "Referer must not be set for api.anthropic.com")
    }

    func testParseRetryAfterAcceptsIntegerSeconds() {
        let resp = HTTPURLResponse(
            url: URL(string: "x://y")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "  42 "]
        )!
        XCTAssertEqual(ClaudeAPIClient.parseRetryAfter(resp), 42)
    }

    func testParseRetryAfterReturnsNilForHTTPDate() {
        // HTTP-date form is rare on Anthropic surfaces; we explicitly fall
        // through to nil so the caller uses its own default back-off.
        let resp = HTTPURLResponse(
            url: URL(string: "x://y")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]
        )!
        XCTAssertNil(ClaudeAPIClient.parseRetryAfter(resp))
    }
}
