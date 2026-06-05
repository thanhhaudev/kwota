//
//  CodexAuthReader.swift
//  Kwota
//
//  Reads `~/.codex/auth.json` — Codex CLI's OAuth credential store.
//  Permissive: every field is optional, malformed sub-trees degrade to nil
//  rather than throwing.
//
//  The `id_token` JWT is parsed (header.payload.signature) to extract the
//  `email` claim. Signature is NOT verified — we trust Codex CLI to have
//  written a valid token; if the email claim is absent we simply return nil.
//

import Foundation

struct CodexAuthReader {
    /// What the reader produces. All fields optional except access_token —
    /// without access_token the reader returns nil (no Codex session).
    struct Auth: Equatable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let accountId: String?
        let email: String?
        let name: String?
        let subscriptionActiveUntil: Date?
    }

    let authFile: URL

    init(authFile: URL = CodexAuthReader.defaultPath) {
        self.authFile = authFile
    }

    static var defaultPath: URL {
        if let dir = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    /// Returns nil when the file is missing, unparseable, or carries no
    /// access_token. Email is extracted from the id_token JWT when present.
    func read() -> Auth? {
        guard
            let data = try? Data(contentsOf: authFile),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        guard
            let tokens = root["tokens"] as? [String: Any],
            let accessToken = tokens["access_token"] as? String,
            !accessToken.isEmpty
        else {
            return nil
        }
        let idToken = tokens["id_token"] as? String
        let payload = idToken.flatMap(Self.decodePayload(_:))
        let email = payload?["email"] as? String
        let name = payload?["name"] as? String
        let subscriptionActiveUntil = Self.subscriptionActiveUntil(from: payload)
        return Auth(
            accessToken: accessToken,
            refreshToken: tokens["refresh_token"] as? String,
            idToken: idToken,
            accountId: tokens["account_id"] as? String,
            email: email,
            name: name,
            subscriptionActiveUntil: subscriptionActiveUntil
        )
    }

    /// Decodes a JWT payload segment to a JSON dictionary. Signature is
    /// intentionally NOT verified (we trust Codex CLI to have written a
    /// valid token). Returns nil when the token is malformed or the
    /// payload isn't a JSON object.
    static func decodePayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-pad to a multiple of 4 — base64url omits padding.
        let pad = (4 - b64.count % 4) % 4
        b64 += String(repeating: "=", count: pad)
        guard
            let data = Data(base64Encoded: b64),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    /// Legacy email-only accessor kept for binary compatibility with the
    /// few existing call sites that may still use it. New code should
    /// read the `email` key off `decodePayload(_:)` directly.
    static func emailFromJWT(_ token: String) -> String? {
        decodePayload(token)?["email"] as? String
    }

    /// Pulls the `chatgpt_subscription_active_until` claim from the
    /// nested `https://api.openai.com/auth` object inside the JWT
    /// payload, parsing it as an ISO8601 timestamp. Returns nil when
    /// the subtree is missing, not a dict, the key is absent, or the
    /// value isn't a parseable date.
    static func subscriptionActiveUntil(from payload: [String: Any]?) -> Date? {
        guard let payload,
              let openai = payload["https://api.openai.com/auth"] as? [String: Any],
              let raw = openai["chatgpt_subscription_active_until"] as? String
        else {
            return nil
        }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: raw) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: raw)
    }
}

/// Test seam — `CodexTokenRefresher` reads through this protocol so tests
/// can substitute an in-memory stub without hitting `~/.codex/auth.json`.
protocol CodexAuthReaderProviding {
    func read() -> CodexAuthReader.Auth?
}

extension CodexAuthReader: CodexAuthReaderProviding {}
