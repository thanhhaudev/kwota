//
//  CacheCleaner.swift
//  Kwota
//

import Foundation

final class CacheCleaner {
    private let targets: [URL]
    private let fm: FileManager
    /// When true, `clean()` deletes children outright (`removeItem`)
    /// instead of moving them to the Trash. Irreversible — the caller is
    /// responsible for having confirmed with the user first.
    private let deletePermanently: Bool

    init(
        targets: [URL] = CacheCleaner.defaultTargets(),
        deletePermanently: Bool = false,
        fileManager: FileManager = .default
    ) {
        self.targets = targets
        self.deletePermanently = deletePermanently
        self.fm = fileManager
    }

    func scan() -> CacheReport {
        let entries = targets.map { entry(for: $0) }
        let report = CacheReport(entries: entries)
        AppLog.shared.log(
            "CacheCleaner scan: \(report.totalFiles) files, \(report.totalBytes) bytes across \(entries.count) paths",
            level: .info
        )
        for e in entries where e.fileCount > 0 {
            AppLog.shared.log("  • \(e.path.path) — \(e.fileCount) files / \(e.bytes) bytes (NOT deleted)", level: .info)
        }
        return report
    }

    /// Progressive variant — yields each `CacheReport.Entry` as soon as
    /// its enumeration completes, so the popover can populate rows live
    /// instead of waiting for the slowest path. Internally same
    /// `TaskGroup` workpool as `scanConcurrent`; the only difference is
    /// the consumer-facing shape (`AsyncStream` instead of accumulating
    /// into an array).
    ///
    /// Stream completion (`continuation.finish()`) happens only after
    /// every per-path task returns, so the caller can use the
    /// `for-await` loop end as the "scan done" signal — no separate
    /// completion callback needed.
    func scanStream(maxConcurrent: Int = 4) -> AsyncStream<CacheReport.Entry> {
        let urls = targets
        let fm = self.fm
        return AsyncStream { continuation in
            // `Task.detached` so the work is guaranteed off the calling
            // actor regardless of where `scanStream` is invoked from —
            // otherwise a @MainActor caller would pin the TaskGroup to
            // main and serialize everything.
            Task.detached(priority: .utility) {
                await withTaskGroup(of: CacheReport.Entry.self) { group in
                    var iter = urls.makeIterator()
                    for _ in 0..<maxConcurrent {
                        guard let url = iter.next() else { break }
                        group.addTask { Self.makeEntry(url: url, fm: fm) }
                    }
                    for await done in group {
                        continuation.yield(done)
                        if let url = iter.next() {
                            group.addTask { Self.makeEntry(url: url, fm: fm) }
                        }
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Concurrent variant. Runs up to `maxConcurrent` per-path enumerations
    /// in parallel via `TaskGroup`. On SSDs the wall-clock win is dramatic
    /// when one path (typically Xcode DerivedData) dwarfs the others — that
    /// path no longer blocks every other one.
    ///
    /// Result-array order is completion order, not submission order. Every
    /// caller maps by `entry.path` keyed dictionary anyway, so this is
    /// fine; if a future caller depends on order it should sort by
    /// `targets.firstIndex(of: ...)` at the call site.
    func scanConcurrent(maxConcurrent: Int = 4) async -> CacheReport {
        let urls = targets
        let fm = self.fm
        let entries = await withTaskGroup(of: CacheReport.Entry.self, returning: [CacheReport.Entry].self) { group in
            var iter = urls.makeIterator()
            // Seed the worker pool with up to `maxConcurrent` tasks.
            for _ in 0..<maxConcurrent {
                guard let url = iter.next() else { break }
                group.addTask {
                    Self.makeEntry(url: url, fm: fm)
                }
            }
            // As each finishes, replace it with the next pending URL so we
            // hold steady at `maxConcurrent` workers until the queue drains.
            var collected: [CacheReport.Entry] = []
            for await done in group {
                collected.append(done)
                if let url = iter.next() {
                    group.addTask {
                        Self.makeEntry(url: url, fm: fm)
                    }
                }
            }
            return collected
        }
        let report = CacheReport(entries: entries)
        AppLog.shared.log(
            "CacheCleaner scanConcurrent: \(report.totalFiles) files / \(report.totalBytes) bytes across \(entries.count) paths (max \(maxConcurrent) in-flight)",
            level: .info
        )
        return report
    }

    /// Remove the immediate contents of every target. The target directory
    /// itself is preserved — some tools (npm, Yarn, pnpm) expect their cache
    /// root to exist on the next invocation. By default children go to the
    /// Trash so the user can recover via Finder; when `deletePermanently`
    /// is set they are deleted outright (the caller must have confirmed).
    ///
    /// Per-child failures (permissions on a single subfolder) do not abort
    /// the rest of the run; we collect the first error message per target so
    /// the UI can surface it without flooding the user with one alert per
    /// item.
    func clean() -> CleanReport {
        let entries = targets.map { cleanEntry(for: $0) }
        let report = CleanReport(entries: entries)
        let verb = deletePermanently ? "deleted" : "trashed"
        AppLog.shared.log(
            "CacheCleaner clean: \(report.totalItemsMoved) items / \(report.totalBytesFreed) bytes \(verb) across \(entries.count) paths",
            level: .info
        )
        for e in entries where e.bytesFreed > 0 || e.firstError != nil {
            let suffix = e.firstError.map { " [error: \($0)]" } ?? ""
            AppLog.shared.log(
                "  • \(e.path.path) — \(e.itemsMoved) items / \(e.bytesFreed) bytes \(verb)\(suffix)",
                level: .info
            )
        }
        return report
    }

    private func entry(for url: URL) -> CacheReport.Entry {
        Self.makeEntry(url: url, fm: fm)
    }

    /// Static so `scanConcurrent`'s `TaskGroup` children can call without
    /// capturing `self` (the class isn't Sendable). Pure function: takes a
    /// URL + FileManager, returns the entry. Identical logic to the
    /// previous instance-method body.
    /// Per-target enumeration ceiling. A tracked path can point at a large
    /// tree (e.g. a user-added system cache); without a ceiling one scan
    /// could run for minutes and the scheduler would repeat it every
    /// interval. Set generously so a legitimate large cache finishes and
    /// reports an exact size (a truncated floor could otherwise keep an
    /// over-cap total under the cap and suppress an auto-clean); the cap is
    /// purely a backstop against a pathological tree, since the Add flow
    /// already allowlists which outside-home paths can be tracked.
    private static let scanTimeBudget: TimeInterval = 30.0

    private static func makeEntry(url: URL, fm: FileManager) -> CacheReport.Entry {
        guard fm.fileExists(atPath: url.path) else {
            return .init(path: url, exists: false, fileCount: 0, bytes: 0)
        }
        var fileCount = 0
        var bytes = 0
        var truncated = false
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
            let deadline = Date().addingTimeInterval(scanTimeBudget)
            var seen = 0
            for case let item as URL in enumerator {
                let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true {
                    fileCount += 1
                    bytes += values?.fileSize ?? 0
                }
                seen += 1
                // Check time only every 4096 items — calling `Date()` per item
                // would itself dominate the walk. Stops a pathological tree
                // from making the scan run unboundedly.
                if seen & 0xFFF == 0, Date() >= deadline {
                    truncated = true
                    break
                }
            }
        }
        return .init(path: url, exists: true, fileCount: fileCount, bytes: bytes, truncated: truncated)
    }

    /// Compute size of a single URL (file or subtree) before trashing it,
    /// so we can report bytes freed. Failing to read size doesn't block the
    /// trash op — we just count zero for that item.
    private func sizeOf(_ url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey])
        if values?.isRegularFile == true {
            return values?.fileSize ?? 0
        }
        // Directory — sum its enumerated regular files.
        var total = 0
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let item as URL in enumerator {
                let v = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true {
                    total += v?.fileSize ?? 0
                }
            }
        }
        return total
    }

    private func cleanEntry(for url: URL) -> CleanReport.Entry {
        guard fm.fileExists(atPath: url.path) else {
            return .init(path: url, bytesFreed: 0, itemsMoved: 0, firstError: nil, trashedItemURLs: [])
        }
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            return .init(path: url, bytesFreed: 0, itemsMoved: 0, firstError: error.localizedDescription, trashedItemURLs: [])
        }
        var freed = 0
        var moved = 0
        var firstErr: String?
        var trashedURLs: [URL] = []
        for child in children {
            let size = sizeOf(child)
            do {
                if deletePermanently {
                    // Hard delete — no Trash, nothing to track for the
                    // auto-empty sweep. Irreversible by design.
                    try fm.removeItem(at: child)
                } else {
                    // `trashItem` writes the post-move location into an
                    // inout NSURL pointer. We capture it so the auto-empty
                    // sweep can find these items in ~/.Trash later. Items
                    // the user has already restored or rearranged are
                    // simply missing from the tracked location when the
                    // sweep runs; that's a benign no-op.
                    var resulting: NSURL?
                    try fm.trashItem(at: child, resultingItemURL: &resulting)
                    if let r = resulting as URL? {
                        trashedURLs.append(r)
                    }
                }
                freed += size
                moved += 1
            } catch {
                if firstErr == nil {
                    firstErr = error.localizedDescription
                }
            }
        }
        return .init(path: url, bytesFreed: freed, itemsMoved: moved, firstError: firstErr, trashedItemURLs: trashedURLs)
    }

    static func defaultTargets() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".cache"),
            home.appendingPathComponent("Library/Caches")
        ]
    }
}
