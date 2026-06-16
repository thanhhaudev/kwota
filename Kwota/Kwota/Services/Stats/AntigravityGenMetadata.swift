//  AntigravityGenMetadata.swift
//  Kwota
//
//  Pure decoder for one Antigravity `gen_metadata.data` protobuf blob. Field
//  paths were reverse-engineered + validated against real conversation DBs:
//    1.4.2 input · 1.4.3 output · 1.4.5 cache-read · 1.4.9 thinking
//    1.4.6==24 structural constant
//    1.9.4.1 per-turn unix-seconds timestamp
//  `1.4.1` is a model/tier id (1016 Pro·High, 1020 Flash·Medium, 1187 Flash·Low,
//  1132 Flash·High, …), NOT a structural invariant — it must never gate validity,
//  or headless `agy -p` one-shots on newer/cheaper tiers vanish from Stats.
//    1.19 api model id · 1.21 display model name
//  No IO — unit-testable in isolation. Returns nil for anything that isn't a
//  trustworthy usage row, so a format drift degrades to "no data" not bad data.

import Foundation

struct AntigravityTurnUsage: Equatable {
    var tokens: TokenBreakdown
    var timestamp: Date?      // nil when 1.9.4.1 is absent/implausible (reader fills a fallback)
    var model: String?
}

/// Outcome of decoding one `gen_metadata` blob. The reader treats these very
/// differently: `notUsage` is a cleanly-read row that simply isn't a usage record
/// (advance the cursor, never retry), while `malformed` signals field-map drift /
/// a torn read (defer for retry, and a whole batch of them holds the cursor).
/// Collapsing the two would re-query legitimate non-usage rows on every poll.
enum AntigravityRowDecode: Equatable {
    case usage(AntigravityTurnUsage)
    case notUsage     // valid protobuf, but no `1.4.2` — legitimately not a usage row
    case malformed    // structural-constant disagreement or implausible magnitude — drift/torn
}

/// Classify one `gen_metadata` blob into usage / not-a-usage-row / malformed.
func classifyAntigravityGenMetadata(_ blob: Data) -> AntigravityRowDecode {
    let r = ProtobufScanner.scan(blob, wanted: [
        "1.4.2", "1.4.3", "1.4.5", "1.4.6", "1.4.9", "1.9.4.1", "1.19", "1.21",
    ])

    guard let input = r.varints["1.4.2"]?.first else {
        // No usage field. A cleanly-parsed blob is simply a non-usage row (consume
        // it, never retry); a torn/truncated blob is a malformed read — likely a
        // WAL mid-write of a real usage row — so defer it for retry.
        return r.truncated ? .malformed : .notUsage
    }
    let output = r.varints["1.4.3"]?.first ?? 0
    let thinking = r.varints["1.4.9"]?.first ?? 0
    let cache = r.varints["1.4.5"]?.first ?? 0

    // Structural-constant guard (lenient: absent is fine; present-but-wrong = drift).
    // Only `1.4.6` is a true invariant; `1.4.1` is a model/tier id (see header) and
    // must NOT gate validity, else newer tiers are dropped as phantom drift.
    if let c6 = r.varints["1.4.6"]?.first, c6 != 24 { return .malformed }

    // Magnitude sanity — a real turn never approaches 1e8 tokens.
    let cap: UInt64 = 100_000_000
    guard input <= cap, output <= cap, thinking <= cap, cache <= cap else { return .malformed }

    var timestamp: Date?
    if let raw = r.varints["1.9.4.1"]?.first, (1_600_000_000...1_900_000_000).contains(raw) {
        timestamp = Date(timeIntervalSince1970: TimeInterval(raw))
    }

    let model = r.strings["1.21"]?.first ?? r.strings["1.19"]?.first
    let tokens = TokenBreakdown(input: Int(input),
                                output: Int(output) + Int(thinking),   // thinking is billable output
                                cacheCreation: 0,                       // Gemini: cache-read only
                                cacheRead: Int(cache))
    return .usage(AntigravityTurnUsage(tokens: tokens, timestamp: timestamp, model: model))
}

/// Usage-only convenience: nil for both non-usage and malformed rows. Callers that
/// must distinguish the two use `classifyAntigravityGenMetadata` directly.
func decodeAntigravityGenMetadata(_ blob: Data) -> AntigravityTurnUsage? {
    if case .usage(let u) = classifyAntigravityGenMetadata(blob) { return u }
    return nil
}
