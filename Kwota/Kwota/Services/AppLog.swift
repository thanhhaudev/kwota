//
//  AppLog.swift
//  Kwota
//

import Foundation
import OSLog

final class AppLog {
    static let shared = AppLog()

    // TODO(post-usage): align subsystem casing with bundle id "com.thanhhaudev.Kwota" for consistent Console.app filtering.
    private let osLog = Logger(subsystem: "com.thanhhaudev.kwota", category: "app")
    private let queue = DispatchQueue(label: "com.thanhhaudev.kwota.log")
    private var buffer: [String] = []
    private let maxLines = 500

    private init() {}

    func log(_ message: String, level: Level = .info) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] [\(level.rawValue)] \(message)"
        queue.sync {
            buffer.append(line)
            if buffer.count > maxLines { buffer.removeFirst(buffer.count - maxLines) }
        }
        switch level {
        case .debug: osLog.debug("\(message, privacy: .public)")
        case .info:  osLog.info("\(message, privacy: .public)")
        case .warn:  osLog.warning("\(message, privacy: .public)")
        case .error: osLog.error("\(message, privacy: .public)")
        }
    }

    func snapshot() -> [String] { queue.sync { buffer } }

    enum Level: String { case debug, info, warn, error }
}
