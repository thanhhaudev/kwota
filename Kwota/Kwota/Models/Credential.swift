//
//  Credential.swift
//  Kwota
//
//  Secret payload stored in Keychain, keyed by Profile.id.
//  NOT persisted to profiles.json.
//

import Foundation

enum Credential: Codable, Equatable {
    case sessionKey(value: String)
    case cliToken(accessToken: String, refreshToken: String, expiresAt: Date)

    private enum Kind: String, Codable { case sessionKey, cliToken }

    private enum CodingKeys: String, CodingKey {
        case kind, value, accessToken, refreshToken, expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .sessionKey:
            self = .sessionKey(value: try c.decode(String.self, forKey: .value))
        case .cliToken:
            self = .cliToken(
                accessToken: try c.decode(String.self, forKey: .accessToken),
                refreshToken: try c.decode(String.self, forKey: .refreshToken),
                expiresAt: try c.decode(Date.self, forKey: .expiresAt)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionKey(let value):
            try c.encode(Kind.sessionKey, forKey: .kind)
            try c.encode(value, forKey: .value)
        case .cliToken(let access, let refresh, let expires):
            try c.encode(Kind.cliToken, forKey: .kind)
            try c.encode(access, forKey: .accessToken)
            try c.encode(refresh, forKey: .refreshToken)
            try c.encode(expires, forKey: .expiresAt)
        }
    }
}
