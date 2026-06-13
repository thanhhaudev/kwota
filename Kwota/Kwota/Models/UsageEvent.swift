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
    /// Model id from `message.model` (e.g. "claude-opus-4-8"). Optional so
    /// existing call sites and test fakes keep compiling; nil when the source
    /// line omits it. Used by the Stats rollup for per-model aggregation.
    let model: String?

    init(uuid: String, sessionId: String, timestamp: Date, tokens: TokenBreakdown, model: String? = nil) {
        self.uuid = uuid
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.tokens = tokens
        self.model = model
    }
}
