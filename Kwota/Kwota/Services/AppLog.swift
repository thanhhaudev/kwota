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
        // `.private` defaults the os_log path to redacted because callers
        // pass an already-interpolated `String` — once it lands here we
        // can't tell whether it carries a token, refresh token, email, or
        // anything else sensitive. The in-app Debug tab reads `buffer`
        // (unredacted) so developers still see full content there; only
        // Console.app / sysdiagnose see `<private>`. To intentionally log
        // a safe diagnostic string to Console, use `log(_:level:privacy:)`.
        switch level {
        case .debug: osLog.debug("\(message, privacy: .private)")
        case .info:  osLog.info("\(message, privacy: .private)")
        case .warn:  osLog.warning("\(message, privacy: .private)")
        case .error: osLog.error("\(message, privacy: .private)")
        }
    }

    func snapshot() -> [String] { queue.sync { buffer } }

    enum Level: String { case debug, info, warn, error }
}
