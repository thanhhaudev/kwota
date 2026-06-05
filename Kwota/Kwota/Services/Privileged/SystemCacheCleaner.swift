//
//  SystemCacheCleaner.swift
//  Kwota
//
//  Pure, root-agnostic logic for clearing the *contents* of a system cache
//  directory. The directory itself is preserved — macOS rebuilds the cache
//  into it. This same code runs unprivileged in unit tests and as root
//  inside KwotaPrivilegedHelper; there is nothing root-specific here, only
//  `FileManager` calls that succeed when the process happens to be root.
//
//  Compiled into BOTH the Kwota app target and the KwotaPrivilegedHelper
//  target. Foundation only.
//

import Foundation

struct SystemCacheCleaner {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    struct Outcome: Equatable {
        var itemsRemoved: Int
        var bytesFreed: Int64
        var firstError: String?
    }

    /// Permanently delete every immediate child of `directory`. The
    /// directory itself is kept. Per-child failures do not abort the rest;
    /// the first error message is captured. A missing directory is a no-op
    /// success.
    func clearContents(of directory: URL) -> Outcome {
        var outcome = Outcome(itemsRemoved: 0, bytesFreed: 0, firstError: nil)
        guard fileManager.fileExists(atPath: directory.path) else { return outcome }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [])
        } catch {
            outcome.firstError = error.localizedDescription
            return outcome
        }

        for child in children {
            let size = Self.size(of: child, fileManager: fileManager)
            do {
                try fileManager.removeItem(at: child)
                outcome.itemsRemoved += 1
                outcome.bytesFreed += size
            } catch {
                if outcome.firstError == nil {
                    outcome.firstError = error.localizedDescription
                }
            }
        }
        return outcome
    }

    /// Total bytes under `directory` (recursive, regular files only). Returns
    /// 0 for a missing directory. Read-only — used by the privileged helper
    /// (as root) to report a size the unprivileged app cannot read.
    func totalSize(of directory: URL) -> Int64 {
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        return Self.size(of: directory, fileManager: fileManager)
    }

    /// Recursively sum the regular-file bytes under `url` (file or subtree).
    /// Failing to size an item just counts zero for it.
    private static func size(of url: URL, fileManager: FileManager) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values?.isRegularFile == true {
            return Int64(values?.fileSize ?? 0)
        }
        var total: Int64 = 0
        if let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) {
            for case let item as URL in enumerator {
                let v = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true {
                    total += Int64(v?.fileSize ?? 0)
                }
            }
        }
        return total
    }
}
