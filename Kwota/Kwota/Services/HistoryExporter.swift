//
//  HistoryExporter.swift
//  Kwota
//

import Foundation

/// Pure transforms over a list of `UsageHistoryEntry` for export. No file
/// IO — callers own the `NSSavePanel` and the write.
enum HistoryExporter {
    static func csv(_ entries: [UsageHistoryEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var out = "at,fiveHour,sevenDay\n"
        for e in entries {
            let stamp = formatter.string(from: e.at)
            let five  = e.fiveHour.map { "\($0)" } ?? ""
            let seven = e.sevenDay.map { "\($0)" } ?? ""
            out += "\(stamp),\(five),\(seven)\n"
        }
        return out
    }

    static func json(_ entries: [UsageHistoryEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries)
    }
}
