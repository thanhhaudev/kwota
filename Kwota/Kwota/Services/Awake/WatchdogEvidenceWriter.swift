//
//  WatchdogEvidenceWriter.swift
//  Kwota
//

import Foundation

nonisolated protocol WatchdogEvidenceWriting: Sendable {
    func append(_ event: WatchdogEvent)
}

/// Test/non-live double. Also what a non-`.live` startup gets, so a test host
/// can never write into the user's real Application Support directory.
nonisolated final class NoopWatchdogEvidenceWriter: WatchdogEvidenceWriting {
    func append(_ event: WatchdogEvent) {}
}

/// Bounded, atomically-written ring of watchdog events.
///
/// `url` deliberately has **no default value**. A `.live`-gated default is the
/// landmine that let `ActivityForwardingTests` write fabricated events into the
/// real `activity-events.json`; the composition root passes the path explicitly
/// and tests pass a temp directory.
nonisolated final class FileWatchdogEvidenceWriter: WatchdogEvidenceWriting {
    private struct Envelope: Codable {
        var records: [WatchdogEvent]
    }

    private let url: URL
    private let maxRecords: Int
    /// Serialises concurrent appends. In production only the watchdog queue
    /// calls this, but the main actor's mutual-watch path also writes.
    private let lock = NSLock()

    init(url: URL, maxRecords: Int = 50) {
        self.url = url
        self.maxRecords = maxRecords
    }

    func append(_ event: WatchdogEvent) {
        lock.lock()
        defer { lock.unlock() }

        // A corrupt or missing file must never swallow new evidence — start a
        // fresh ring rather than propagating the decode failure.
        var records = (try? Self.load(from: url)) ?? []
        records.append(event)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }

        do {
            let data = try Self.encoder().encode(Envelope(records: records))
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            // Swallowed on purpose: the assertion release matters more than
            // its paper trail, and this runs on the release path.
            AppLog.shared.log(
                "WatchdogEvidenceWriter: write failed at \(url.path): \(error)",
                level: .warn
            )
        }
    }

    static func load(from url: URL) throws -> [WatchdogEvent] {
        let data = try Data(contentsOf: url)
        return try decoder().decode(Envelope.self, from: data).records
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
