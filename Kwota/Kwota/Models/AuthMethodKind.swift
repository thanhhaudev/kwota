//
//  AuthMethodKind.swift
//  Kwota
//

import Foundation

enum AuthMethodKind: String, Codable, Equatable, CaseIterable {
    case cliSync     // reads ~/.claude/.credentials.json on each fetch
    case sessionKey  // user-pasted claude.ai cookie
}
