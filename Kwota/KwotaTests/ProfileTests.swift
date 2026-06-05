import XCTest
@testable import Kwota

final class ProfileTests: XCTestCase {
    func testMaskedEmail() {
        let p = Profile(id: UUID(), name: "Test", authMethod: .sessionKey, email: "thanhhaudev@gmail.com")
        XCTAssertEqual(p.maskedEmail, "t••••@gmail.com")
        
        let pShort = Profile(id: UUID(), name: "Test", authMethod: .sessionKey, email: "a@b.com")
        XCTAssertEqual(pShort.maskedEmail, "a••••@b.com")
        
        let pNone = Profile(id: UUID(), name: "Test", authMethod: .sessionKey, email: nil)
        XCTAssertNil(pNone.maskedEmail)
    }

    func testMaskedPlan() {
        var p = Profile(id: UUID(), name: "Test", authMethod: .sessionKey)
        XCTAssertNil(p.maskedPlan)

        p.subscriptionPlan = "Claude Pro"
        XCTAssertEqual(p.maskedPlan, "•••• Plan")
    }

    func testProviderIDDefaultsToClaudeWhenAbsentInJSON() throws {
        let legacy = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "Old",
          "authMethod": "cliSync",
          "createdAt": 1700000000
        }
        """
        let data = Data(legacy.utf8)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let p = try dec.decode(Profile.self, from: data)
        XCTAssertEqual(p.providerID, .claude)
    }

    func testProviderIDDecoderCoercesUnknownRawValueToClaude() throws {
        // A profiles.json written by a future build (or hand-edited) with a
        // providerID raw value we don't recognise must decode as .claude
        // rather than crash the load.
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Future",
          "authMethod": "cliSync",
          "providerID": "openai",
          "createdAt": 1700000000
        }
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let decoded = try dec.decode(Profile.self, from: json)
        XCTAssertEqual(decoded.providerID, .claude)
    }

    func testProviderIDClaudeRoundTrip() throws {
        let p = Profile(id: UUID(), name: "Test", authMethod: .cliSync, providerID: .claude)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        let data = try enc.encode(p)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let decoded = try dec.decode(Profile.self, from: data)
        XCTAssertEqual(decoded.providerID, .claude)
    }

    func test_decoder_defaultsKindToAuto_whenMissing() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy",
            "authMethod": "cliSync",
            "createdAt": 1700000000
        }
        """.data(using: .utf8)!
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        let p = try d.decode(Profile.self, from: json)
        XCTAssertEqual(p.kind, .auto)
        XCTAssertNil(p.ownershipBoundary)
    }

    func test_decoder_decodesArchivedKind() throws {
        let json = """
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "name": "Old",
            "authMethod": "sessionKey",
            "createdAt": 1700000000,
            "kind": "archived",
            "ownershipBoundary": 1700000500
        }
        """.data(using: .utf8)!
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        let p = try d.decode(Profile.self, from: json)
        XCTAssertEqual(p.kind, .archived)
        XCTAssertEqual(p.ownershipBoundary, Date(timeIntervalSince1970: 1700000500))
    }

    func test_roundTrip_preservesKindAndBoundary() throws {
        let boundary = Date(timeIntervalSince1970: 1700000500)
        let p = Profile(
            name: "RT",
            authMethod: .cliSync,
            kind: .auto,
            ownershipBoundary: boundary
        )
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        let data = try e.encode(p)
        let back = try d.decode(Profile.self, from: data)
        XCTAssertEqual(back.kind, .auto)
        XCTAssertEqual(back.ownershipBoundary, boundary)
    }

    // MARK: - Schema migration: 7 new optional fields

    func test_decodeOldJSON_missingNewFields_defaultsToNil() throws {
        let json = """
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "name": "Legacy",
            "authMethod": "cliSync",
            "createdAt": 1700000000
        }
        """.data(using: .utf8)!
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        let p = try d.decode(Profile.self, from: json)
        XCTAssertNil(p.accountUuid)
        XCTAssertNil(p.displayName)
        XCTAssertNil(p.accountCreatedAt)
        XCTAssertNil(p.organizationName)
        XCTAssertNil(p.subscriptionStatus)
        XCTAssertNil(p.billingType)
        XCTAssertNil(p.hasExtraUsageEnabled)
    }

    func test_decodeNewJSON_populatesAllNewFields() throws {
        let json = """
        {
            "id": "44444444-4444-4444-4444-444444444444",
            "name": "New",
            "authMethod": "cliSync",
            "createdAt": 1700000000,
            "accountUuid": "acc-uuid-1",
            "displayName": "Hau",
            "accountCreatedAt": 1700100000,
            "organizationName": "Hau's Org",
            "subscriptionStatus": "active",
            "billingType": "stripe_subscription",
            "hasExtraUsageEnabled": false
        }
        """.data(using: .utf8)!
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        let p = try d.decode(Profile.self, from: json)
        XCTAssertEqual(p.accountUuid, "acc-uuid-1")
        XCTAssertEqual(p.displayName, "Hau")
        XCTAssertEqual(p.accountCreatedAt, Date(timeIntervalSince1970: 1700100000))
        XCTAssertEqual(p.organizationName, "Hau's Org")
        XCTAssertEqual(p.subscriptionStatus, "active")
        XCTAssertEqual(p.billingType, "stripe_subscription")
        XCTAssertEqual(p.hasExtraUsageEnabled, false)
    }

    func test_roundTrip_encodeDecodeProfile_withAllNewFields() throws {
        let accountCreated = Date(timeIntervalSince1970: 1700200000)
        let p = Profile(
            name: "RT-full",
            authMethod: .cliSync,
            accountUuid: "acc-rt",
            displayName: "RT",
            accountCreatedAt: accountCreated,
            organizationName: "RT Org",
            subscriptionStatus: "trial",
            billingType: "stripe_subscription",
            hasExtraUsageEnabled: true
        )
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        let data = try e.encode(p)
        let back = try d.decode(Profile.self, from: data)
        XCTAssertEqual(back.accountUuid, "acc-rt")
        XCTAssertEqual(back.displayName, "RT")
        XCTAssertEqual(back.accountCreatedAt, accountCreated)
        XCTAssertEqual(back.organizationName, "RT Org")
        XCTAssertEqual(back.subscriptionStatus, "trial")
        XCTAssertEqual(back.billingType, "stripe_subscription")
        XCTAssertEqual(back.hasExtraUsageEnabled, true)
    }

    func test_roundTrip_encodeDecodeProfile_withNilNewFields() throws {
        let p = Profile(name: "RT-nil", authMethod: .cliSync)
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        let data = try e.encode(p)
        let back = try d.decode(Profile.self, from: data)
        XCTAssertNil(back.accountUuid)
        XCTAssertNil(back.displayName)
        XCTAssertNil(back.accountCreatedAt)
        XCTAssertNil(back.organizationName)
        XCTAssertNil(back.subscriptionStatus)
        XCTAssertNil(back.billingType)
        XCTAssertNil(back.hasExtraUsageEnabled)
    }

    func test_subscriptionRenewsAt_roundTripsThroughJSON() throws {
        let renewsAt = Date(timeIntervalSince1970: 1_780_000_000)
        let p = Profile(
            name: "Hau",
            authMethod: .cliSync,
            providerID: .codex,
            subscriptionRenewsAt: renewsAt,
            email: "u@x.com"
        )
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let data = try enc.encode(p)
        let restored = try dec.decode(Profile.self, from: data)
        XCTAssertEqual(
            restored.subscriptionRenewsAt?.timeIntervalSince1970.rounded(),
            renewsAt.timeIntervalSince1970.rounded(),
            "subscriptionRenewsAt must survive a JSON round-trip"
        )
    }

    func test_subscriptionRenewsAt_defaultsToNil_whenAbsentInJSON() throws {
        // Simulate a profiles.json written by a binary that predates this
        // field — the key simply isn't present.
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Hau",
          "authMethod": "cliSync",
          "providerID": "codex",
          "createdAt": 1780000000,
          "kind": "auto"
        }
        """.data(using: .utf8)!

        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let decoded = try dec.decode(Profile.self, from: json)
        XCTAssertNil(decoded.subscriptionRenewsAt,
                     "Profiles persisted before this feature must decode with nil")
    }
}
