//
//  CLICredentialReader.swift
//  Kwota
//
//  Reads Claude Code's saved OAuth credentials and converts them into a
//  Credential.cliToken. Newer Claude Code versions store credentials in the
//  macOS Keychain (service "Claude Code-credentials"); older versions wrote
//  to ~/.claude/.credentials.json. We try Keychain first, then fall back to
//  the legacy file. We never refresh these tokens — Claude Code is the
//  source of truth.
//

import Foundation
import Security

struct CLICredentialReader {
    typealias KeychainProbe = () -> Data?

    let credentialsFile: URL
    private let keychainProbe: KeychainProbe

    init(
        credentialsFile: URL = CLICredentialReader.defaultPath,
        keychainProbe: @escaping KeychainProbe = CLICredentialReader.defaultKeychainProbe
    ) {
        self.credentialsFile = credentialsFile
        self.keychainProbe = keychainProbe
    }

    static var defaultPath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/.credentials.json")
    }

    static let keychainService = "Claude Code-credentials"

    static let defaultKeychainProbe: KeychainProbe = {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    /// True when Claude Code's legacy credentials file exists. Intentionally
    /// does NOT probe the Keychain — a probe would trigger the cross-app
    /// consent prompt for a mere availability check. The real read path
    /// (`read()`) still tries the Keychain first when a credential is needed.
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: credentialsFile.path)
    }

    struct SyncResult: Equatable {
        let credential: Credential
        let subscriptionPlan: String?
    }

    private struct Payload: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let subscriptionType: String?
    }

    private struct KeychainEnvelope: Decodable {
        let claudeAiOauth: Payload
        enum CodingKeys: String, CodingKey { case claudeAiOauth }
    }

    func read() throws -> SyncResult {
        if let data = keychainProbe(), let result = decodeKeychainPayload(data) {
            return result
        }
        let data = try Data(contentsOf: credentialsFile)
        let payload = try Self.decoder().decode(Payload.self, from: data)
        return SyncResult(
            credential: .cliToken(
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken,
                expiresAt: payload.expiresAt
            ),
            subscriptionPlan: payload.subscriptionType
        )
    }

    private func decodeKeychainPayload(_ data: Data) -> SyncResult? {
        let decoder = Self.decoder()
        if let envelope = try? decoder.decode(KeychainEnvelope.self, from: data) {
            return makeResult(envelope.claudeAiOauth)
        }
        if let p = try? decoder.decode(Payload.self, from: data) {
            return makeResult(p)
        }
        return nil
    }

    private func makeResult(_ p: Payload) -> SyncResult {
        SyncResult(
            credential: .cliToken(
                accessToken: p.accessToken,
                refreshToken: p.refreshToken,
                expiresAt: p.expiresAt
            ),
            subscriptionPlan: p.subscriptionType
        )
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            // Try ISO8601 string first, then numeric epoch (sec or ms).
            if let s = try? c.decode(String.self) {
                // TODO(post-usage): cache static ISO8601DateFormatter; per-line allocation is wasteful if reused on larger files.
                if let d = ISO8601DateFormatter().date(from: s) { return d }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad ISO8601: \(s)")
            }
            let n = try c.decode(Double.self)
            // Heuristic: anything > 10^12 is milliseconds.
            return n > 1_000_000_000_000 ? Date(timeIntervalSince1970: n / 1000) : Date(timeIntervalSince1970: n)
        }
        return d
    }
}
