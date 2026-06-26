//
//  UsageHistoryStore.swift
//  Kwota
//
//  Per-profile JSON-backed history. Caps separately by snapshot kind:
//   - session entries (fiveHour != nil) keep newest sessionCap.
//   - weekly entries  (sevenDay != nil) keep newest weeklyCap.
//  An entry with both fields counts toward both caps.
//

import Foundation
import AppKit

@MainActor
final class UsageHistoryStore {
    private let historyFile: URL
    private let sessionCap: Int
    private let weeklyCap: Int
    private let writeDebounce: TimeInterval
    private var entries: [UsageHistoryEntry] = []
    private var loaded = false
    private var pendingWriteTask: Task<Void, Never>?
    private var willTerminateObserver: NSObjectProtocol?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    init(
        historyFile: URL,
        sessionCap: Int? = nil,
        weeklyCap: Int? = nil,
        writeDebounce: TimeInterval = 10,
        defaults: UserDefaults = .standard
    ) {
        self.historyFile = historyFile
        self.sessionCap = sessionCap
            ?? defaults.integer(forKey: AppStorageKeys.generalUsageHistorySessionCap).nonZeroOr(1000)
        self.weeklyCap = weeklyCap
            ?? defaults.integer(forKey: AppStorageKeys.generalUsageHistoryWeeklyCap).nonZeroOr(500)
        self.writeDebounce = writeDebounce
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Synchronously flush any pending debounced write before the
            // process exits. MenuBarExtra apps quit fast; a 10s debounce
            // window otherwise drops the just-appended entry. Notification
            // is delivered on `queue: .main`, so assumeIsolated is sound.
            MainActor.assumeIsolated {
                try? self?.flushPendingWrite()
            }
        }
    }

    deinit {
        if let willTerminateObserver {
            NotificationCenter.default.removeObserver(willTerminateObserver)
        }
    }

    func load() throws -> [UsageHistoryEntry] {
        try ensureLoaded()
        return entries
    }

    @discardableResult
    func append(_ entry: UsageHistoryEntry) throws -> UsageHistoryEntry {
        try ensureLoaded()
        let entry = normalizedForStorage(entry)
        // Run-length dedup. Refresh fires every popover open / coord tick /
        // manual click, so a quiet quota window produces a long run of
        // identical (fiveHour, sevenDay) readings. Each one would burn an
        // entry slot for zero chart info — the chart re-draws the same
        // point. Collapse those into two anchors instead: the entry that
        // started the plateau, plus a sliding tail that tracks the latest
        // sample's timestamp. When the value changes, normal append resumes
        // and the new run begins, preserving the plateau's true bounds.
        //
        // The two-back check is the wedge between "starting a plateau"
        // (only the immediate predecessor matches → keep both as the
        // bookends) and "extending one" (predecessor AND its predecessor
        // match → tail is mid-run, slide it forward). Without the second
        // check we'd lose the plateau's start timestamp on the very first
        // duplicate, drawing the chart as if the run began later than it did.
        if entries.count >= 2,
           sameReading(entry, entries[entries.count - 1]),
           sameReading(entries[entries.count - 1], entries[entries.count - 2]) {
            let tail = entries[entries.count - 1]
            entries[entries.count - 1] = UsageHistoryEntry(
                id: tail.id,
                at: entry.at,
                fiveHour: entry.fiveHour,
                sevenDay: entry.sevenDay
            )
        } else {
            entries.append(entry)
        }
        applyCaps()
        scheduleWrite()
        return entry
    }

    private func sameReading(_ a: UsageHistoryEntry, _ b: UsageHistoryEntry) -> Bool {
        a.fiveHour == b.fiveHour && a.sevenDay == b.sevenDay
    }

    private func normalizedForStorage(_ entry: UsageHistoryEntry) -> UsageHistoryEntry {
        guard let weekly = entry.sevenDay,
              let previousWeekly = entries.last(where: { $0.sevenDay != nil }),
              previousWeekly.sevenDay == weekly,
              previousWeekly.fiveHour != entry.fiveHour
        else { return entry }

        return UsageHistoryEntry(
            id: entry.id,
            at: entry.at,
            fiveHour: entry.fiveHour,
            sevenDay: nil
        )
    }

    /// Forces any pending debounced write to complete synchronously. Called from the willTerminate observer to avoid losing the just-appended entry when the app quits within the debounce window.
    func flushPendingWrite() throws {
        pendingWriteTask?.cancel()
        pendingWriteTask = nil
        try writeNow()
    }

    // MARK: - Internals

    private func ensureLoaded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: historyFile.path) else { return }
        let data = try Data(contentsOf: historyFile)
        entries = try decoder.decode([UsageHistoryEntry].self, from: data)
        if compactLegacyRepeatedWeeklySamples() {
            applyCaps()
            try writeNow()
        }
    }

    private func compactLegacyRepeatedWeeklySamples() -> Bool {
        entries.sort { $0.at < $1.at }
        var lastWeekly: Double?
        var changed = false
        entries = entries.map { entry in
            guard let weekly = entry.sevenDay else { return entry }
            defer { lastWeekly = weekly }
            guard lastWeekly == weekly else { return entry }
            changed = true
            return UsageHistoryEntry(
                id: entry.id,
                at: entry.at,
                fiveHour: entry.fiveHour,
                sevenDay: nil
            )
        }
        return changed
    }

    private func applyCaps() {
        entries.sort { $0.at < $1.at }

        let sessionIdxs = entries.enumerated().compactMap { $0.element.fiveHour != nil ? $0.offset : nil }
        var sessionIdxsToDrop: [Int] = []
        if sessionIdxs.count > sessionCap {
            sessionIdxsToDrop = Array(sessionIdxs.prefix(sessionIdxs.count - sessionCap))
        }
        let weeklyIdxs = entries.enumerated().compactMap { $0.element.sevenDay != nil ? $0.offset : nil }
        var weeklyIdxsToDrop: [Int] = []
        if weeklyIdxs.count > weeklyCap {
            weeklyIdxsToDrop = Array(weeklyIdxs.prefix(weeklyIdxs.count - weeklyCap))
        }

        let toDrop = Set(sessionIdxsToDrop).union(Set(weeklyIdxsToDrop))
        if !toDrop.isEmpty {
            entries = entries.enumerated().compactMap { idx, e in
                toDrop.contains(idx) ? nil : e
            }
        }
    }

    private func scheduleWrite() {
        pendingWriteTask?.cancel()
        if writeDebounce <= 0 {
            try? writeNow()
            return
        }
        pendingWriteTask = Task { [weak self, writeDebounce] in
            try? await Task.sleep(nanoseconds: UInt64(writeDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            try? self?.writeNow()
        }
    }

    private func writeNow() throws {
        try FileManager.default.createDirectory(
            at: historyFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(entries)
        try data.write(to: historyFile, options: .atomic)
    }
}
