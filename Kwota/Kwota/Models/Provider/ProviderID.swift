//
//  ProviderID.swift
//  Kwota
//

import Foundation

/// Stable identifier for an account provider. Stored in `Profile.providerID`
/// and on the wire in `profiles.json`. Unknown raw values (e.g. legacy
/// profiles missing the field, or a value written by a future build) decode
/// as `.claude` so the load doesn't crash; Claude is the longest-standing
/// provider and the original default.
enum ProviderID: Codable, Hashable, Sendable {
    case claude
    case codex
    case antigravity

    var rawValue: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .antigravity: "antigravity"
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "claude": self = .claude
        case "codex": self = .codex
        case "antigravity": self = .antigravity
        default: self = .claude
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: raw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
