//
//  CodexAuthReaderTests.swift
//

import XCTest
@testable import Kwota

final class CodexAuthReaderTests: XCTestCase {
    private func jwt(claims: [String: Any]) -> String {
        // Minimal unsigned JWT: header.payload.<empty-sig>. Codex auth.json
        // stores real signed JWTs; the reader does NOT verify signatures
        // (we trust Codex CLI to have written a valid file), so an unsigned
        // payload is fine for tests.
        let header = #"{"alg":"none","typ":"JWT"}"#
        let payload = String(data: try! JSONSerialization.data(withJSONObject: claims), encoding: .utf8)!
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(header)).\(b64(payload))."
    }

    func test_read_returnsNilWhenFileMissing() {
        let reader = CodexAuthReader(authFile: URL(fileURLWithPath: "/dev/null/does-not-exist.json"))
        XCTAssertNil(reader.read())
    }

    func test_read_parsesFullAuthJson() throws {
        let token = jwt(claims: ["email": "codex-user@example.com"])
        let json = """
        {
          "OPENAI_API_KEY": "sk-abc",
          "tokens": {
            "access_token": "acc",
            "id_token": "\(token)",
            "refresh_token": "ref",
            "account_id": "acct-123"
          }
        }
        """.data(using: .utf8)!

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try json.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let reader = CodexAuthReader(authFile: tmp)
        let auth = try XCTUnwrap(reader.read())
        XCTAssertEqual(auth.accessToken, "acc")
        XCTAssertEqual(auth.refreshToken, "ref")
        XCTAssertEqual(auth.accountId, "acct-123")
        XCTAssertEqual(auth.email, "codex-user@example.com")
    }

    func test_read_returnsNilEmailWhenJwtMalformed() throws {
        let json = """
        {
          "tokens": { "access_token": "acc", "id_token": "not-a-jwt" }
        }
        """.data(using: .utf8)!

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try json.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let reader = CodexAuthReader(authFile: tmp)
        let auth = try XCTUnwrap(reader.read())
        XCTAssertEqual(auth.accessToken, "acc")
        XCTAssertNil(auth.email,
                     "Malformed id_token must not crash; email simply becomes nil")
    }

    func test_read_returnsNilWhenNoTokens() throws {
        let json = Data(#"{"OPENAI_API_KEY":"sk-abc"}"#.utf8)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try json.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let reader = CodexAuthReader(authFile: tmp)
        // Per spec the reader returns nil when no access_token is present —
        // API-key-only auth doesn't drive a Codex profile yet.
        XCTAssertNil(reader.read())
    }

    func test_read_parsesName_whenTopLevelClaimPresent() throws {
        let token = jwt(claims: [
            "email": "u@x.com",
            "name": "Hau"
        ])
        let json = """
        {
          "tokens": { "access_token": "acc", "id_token": "\(token)" }
        }
        """.data(using: .utf8)!
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try json.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = try XCTUnwrap(CodexAuthReader(authFile: tmp).read())
        XCTAssertEqual(auth.name, "Hau")
    }

    func test_read_nameIsNil_whenTopLevelClaimMissing() throws {
        let token = jwt(claims: ["email": "u@x.com"])
        let json = """
        {
          "tokens": { "access_token": "acc", "id_token": "\(token)" }
        }
        """.data(using: .utf8)!
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try json.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = try XCTUnwrap(CodexAuthReader(authFile: tmp).read())
        XCTAssertNil(auth.name)
    }

    func test_read_parsesSubscriptionActiveUntil_whenNestedClaimPresent() throws {
        let token = jwt(claims: [
            "email": "u@x.com",
            "https://api.openai.com/auth": [
                "chatgpt_subscription_active_until": "2026-06-22T05:31:23+00:00"
            ]
        ])
        let json = """
        {
          "tokens": { "access_token": "acc", "id_token": "\(token)" }
        }
        """.data(using: .utf8)!
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try json.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = try XCTUnwrap(CodexAuthReader(authFile: tmp).read())
        let expected = ISO8601DateFormatter().date(from: "2026-06-22T05:31:23+00:00")
        XCTAssertEqual(auth.subscriptionActiveUntil, expected)
    }

    func test_read_subscriptionActiveUntilIsNil_whenNestedSubtreeMissing() throws {
        let token = jwt(claims: ["email": "u@x.com"])
        let json = """
        {
          "tokens": { "access_token": "acc", "id_token": "\(token)" }
        }
        """.data(using: .utf8)!
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try json.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = try XCTUnwrap(CodexAuthReader(authFile: tmp).read())
        XCTAssertNil(auth.subscriptionActiveUntil)
    }

    func test_read_subscriptionActiveUntilIsNil_whenDateUnparseable() throws {
        let token = jwt(claims: [
            "email": "u@x.com",
            "https://api.openai.com/auth": [
                "chatgpt_subscription_active_until": "not-a-date"
            ]
        ])
        let json = """
        {
          "tokens": { "access_token": "acc", "id_token": "\(token)" }
        }
        """.data(using: .utf8)!
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try json.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = try XCTUnwrap(CodexAuthReader(authFile: tmp).read())
        XCTAssertNil(auth.subscriptionActiveUntil)
    }

    func test_read_subscriptionActiveUntilIsNil_whenNestedSubtreeIsNotObject() throws {
        // The "https://api.openai.com/auth" key is present but as a string
        // instead of an object — degrades gracefully to nil.
        let token = jwt(claims: [
            "email": "u@x.com",
            "https://api.openai.com/auth": "should-be-object"
        ])
        let json = """
        {
          "tokens": { "access_token": "acc", "id_token": "\(token)" }
        }
        """.data(using: .utf8)!
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try json.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = try XCTUnwrap(CodexAuthReader(authFile: tmp).read())
        XCTAssertNil(auth.subscriptionActiveUntil)
    }

    func test_read_parsesPlanType_whenNestedClaimPresent() throws {
        let token = jwt(claims: [
            "email": "u@x.com",
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": "plus"
            ]
        ])
        let json = """
        {
          "tokens": { "access_token": "acc", "id_token": "\(token)" }
        }
        """.data(using: .utf8)!
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try json.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = try XCTUnwrap(CodexAuthReader(authFile: tmp).read())
        XCTAssertEqual(auth.planType, "plus",
                       "chatgpt_plan_type claim must populate Auth.planType")
    }

    func test_read_planTypeIsNil_whenNestedClaimMissing() throws {
        let token = jwt(claims: [
            "email": "u@x.com",
            "https://api.openai.com/auth": [
                "chatgpt_subscription_active_until": "2026-06-22T05:31:23+00:00"
            ]
        ])
        let json = """
        {
          "tokens": { "access_token": "acc", "id_token": "\(token)" }
        }
        """.data(using: .utf8)!
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try json.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = try XCTUnwrap(CodexAuthReader(authFile: tmp).read())
        XCTAssertNil(auth.planType)
    }

    func test_read_planTypeIsNil_whenNestedSubtreeIsNotObject() throws {
        let token = jwt(claims: [
            "email": "u@x.com",
            "https://api.openai.com/auth": "should-be-object"
        ])
        let json = """
        {
          "tokens": { "access_token": "acc", "id_token": "\(token)" }
        }
        """.data(using: .utf8)!
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try json.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = try XCTUnwrap(CodexAuthReader(authFile: tmp).read())
        XCTAssertNil(auth.planType)
    }
}
