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
        Self.evict(&records, downTo: maxRecords)

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

    /// Trims `records` to `limit`, sacrificing notify-only breadcrumbs before
    /// ever touching a `.fired`.
    ///
    /// Plain FIFO over a single shared budget was safe while `.fired` was the
    /// only writer, because a firing is rare by construction — a session either
    /// releases cleanly or the app is already in the bad state this file exists
    /// to document. `.stallObserved` broke that premise: it lands once per stall
    /// *episode*, and an episode is only "main actor quiet past 180s", re-armable
    /// by every heartbeat. A user who steps away repeatedly while an agent
    /// session sits armed generates those all afternoon — no freeze required.
    /// Under FIFO, enough of them evict the firing records outright, which would
    /// mean this branch's own diagnostics destroying the F-003 forensics the
    /// branch was written to capture.
    ///
    /// So the ring is prioritised rather than partitioned: no fixed reservation
    /// to tune and get wrong, and a session that never stalls still gets all
    /// `maxRecords` slots for firings. Within each class eviction stays
    /// oldest-first. Firings can starve breadcrumbs completely, and that is the
    /// intended ordering — `maxRecords` consecutive firings is a story that needs
    /// no footnotes.
    static func evict(_ records: inout [WatchdogEvent], downTo limit: Int) {
        var overflow = records.count - limit
        guard overflow > 0 else { return }
        while overflow > 0, let oldestNotice = records.firstIndex(where: \.isNotifyOnly) {
            records.remove(at: oldestNotice)
            overflow -= 1
        }
        // Only reachable once every remaining record is a firing, at which point
        // this is the original FIFO rule applied to firings alone.
        if overflow > 0 { records.removeFirst(overflow) }
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
