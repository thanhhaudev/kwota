//  AntigravityGenMetadata.swift
//  Kwota
//
//  Pure decoder for one Antigravity `gen_metadata.data` protobuf blob. Field
//  paths were reverse-engineered + validated against real conversation DBs:
//    1.4.2 input · 1.4.3 output · 1.4.5 cache-read · 1.4.9 thinking
//    1.4.1∈{1016,1020}, 1.4.6==24 structural constants
//    1.9.4.1 per-turn unix-seconds timestamp
//    1.19 api model id · 1.21 display model name
//  No IO — unit-testable in isolation. Returns nil for anything that isn't a
//  trustworthy usage row, so a format drift degrades to "no data" not bad data.

import Foundation

struct AntigravityTurnUsage: Equatable {
    var tokens: TokenBreakdown
    var timestamp: Date?      // nil when 1.9.4.1 is absent/implausible (reader fills a fallback)
    var model: String?
}

/// Decode one `gen_metadata` blob. Returns nil when the row is not a usage row
/// (no `1.4.2`), when a present structural constant disagrees (field-map drift),
/// or when any token magnitude is implausibly large (torn read / drift).
func decodeAntigravityGenMetadata(_ blob: Data) -> AntigravityTurnUsage? {
    let r = ProtobufScanner.scan(blob, wanted: [
        "1.4.1", "1.4.2", "1.4.3", "1.4.5", "1.4.6", "1.4.9", "1.9.4.1", "1.19", "1.21",
    ])

    guard let input = r.varints["1.4.2"]?.first else { return nil }   // not a usage row
    let output = r.varints["1.4.3"]?.first ?? 0
    let thinking = r.varints["1.4.9"]?.first ?? 0
    let cache = r.varints["1.4.5"]?.first ?? 0

    // Structural-constant guard (lenient: absent is fine; present-but-wrong = drift).
    if let c1 = r.varints["1.4.1"]?.first, c1 != 1016, c1 != 1020 { return nil }
    if let c6 = r.varints["1.4.6"]?.first, c6 != 24 { return nil }

    // Magnitude sanity — a real turn never approaches 1e8 tokens.
    let cap: UInt64 = 100_000_000
    guard input <= cap, output <= cap, thinking <= cap, cache <= cap else { return nil }

    var timestamp: Date?
    if let raw = r.varints["1.9.4.1"]?.first, (1_600_000_000...1_900_000_000).contains(raw) {
        timestamp = Date(timeIntervalSince1970: TimeInterval(raw))
    }

    let model = r.strings["1.21"]?.first ?? r.strings["1.19"]?.first
    let tokens = TokenBreakdown(input: Int(input),
                                output: Int(output) + Int(thinking),   // thinking is billable output
                                cacheCreation: 0,                       // Gemini: cache-read only
                                cacheRead: Int(cache))
    return AntigravityTurnUsage(tokens: tokens, timestamp: timestamp, model: model)
}
