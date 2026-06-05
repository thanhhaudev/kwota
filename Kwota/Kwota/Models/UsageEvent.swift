//
//  UsageEvent.swift
//  Kwota
//

import Foundation

struct UsageEvent: Codable, Equatable {
    let uuid: String
    let sessionId: String
    let timestamp: Date
    let tokens: TokenBreakdown
}
