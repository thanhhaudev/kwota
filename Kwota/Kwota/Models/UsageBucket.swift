//
//  UsageBucket.swift
//  Kwota
//

import Foundation

struct UsageBucket: Codable, Equatable {
    let utilization: Double?
    let resetsAt: Date?

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    // TODO(post-usage): document edge case — when elapsed % interval == 0 exactly (Double precision dependent), result is previous + (N+1)*interval, not N*interval.
    static func nextReset(from previous: Date?, interval: TimeInterval, now: Date) -> Date {
        guard let previous else { return now.addingTimeInterval(interval) }
        if previous > now { return previous }
        let elapsed = now.timeIntervalSince(previous)
        let stepsAlreadyPassed = floor(elapsed / interval)
        return previous.addingTimeInterval((stepsAlreadyPassed + 1) * interval)
    }
}

extension JSONDecoder {
    /// Shared decoder for the Anthropic OAuth usage payload — handles ISO8601
    /// with optional fractional seconds.
    static func usageDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            let formatters: [ISO8601DateFormatter] = [
                {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f
                }(),
                {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime]
                    return f
                }()
            ]
            for f in formatters {
                if let d = f.date(from: s) { return d }
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad ISO8601: \(s)")
        }
        return dec
    }
}
