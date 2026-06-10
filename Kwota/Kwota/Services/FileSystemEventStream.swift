//
//  FileSystemEventStream.swift
//  Kwota
//
//  Shared kqueue-backed AsyncStream factory for watching a single file at a
//  fixed path. Used by the CLI account watchers (`~/.claude.json` and
//  `~/.codex/auth.json`) whose owners rewrite the file via temp-then-rename
//  on every login/token rotation.
//
//  Why the per-event re-arm: a `DispatchSource.makeFileSystemObjectSource`
//  is bound to the *fd*, not the path. After the first atomic-rename the
//  inode our fd points at is unlinked, and every subsequent write lands on
//  a new inode that our source never hears about. Without re-arming we
//  would silently fall back to the watcher's 60s poll for the rest of the
//  app's lifetime. On `.rename` / `.delete` we cancel the stale source and
//  open a fresh fd against the path.
//

import Foundation

enum FileSystemEventStream {
    /// Watch `path` for write/rename/delete and yield once per event. The
    /// stream re-arms automatically after the watched file is replaced.
    ///
    /// `queueLabel` distinguishes the dispatch queue per watcher in
    /// stack traces. `maxReopenAttempts` and `reopenBackoff` bound the
    /// retry loop when the file is briefly absent between unlink and the
    /// temp-rename landing the new inode — after the budget expires the
    /// stream falls dormant and the owner's poll backstop picks up the
    /// next change.
    static func observe(
        path: String,
        queueLabel: String,
        maxReopenAttempts: Int = 5,
        reopenBackoff: TimeInterval = 0.1
    ) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: queueLabel)
            // Holder so the (re-armed) live source can be reached from both
            // the queue closures and the stream-termination handler. All
            // mutation happens on `queue` (the termination handler hops onto
            // it before touching `source`), so the unchecked Sendable is
            // sound — the serial queue is the synchronization point.
            final class Holder: @unchecked Sendable { var source: DispatchSourceFileSystemObject? }
            let holder = Holder()

            func arm(attempt: Int) {
                let fd = open(path, O_EVTONLY)
                if fd == -1 {
                    if attempt < maxReopenAttempts {
                        queue.asyncAfter(deadline: .now() + reopenBackoff) {
                            arm(attempt: attempt + 1)
                        }
                    }
                    return
                }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .rename, .delete],
                    queue: queue
                )
                source.setEventHandler {
                    let mask = source.data
                    continuation.yield(())
                    if mask.contains(.rename) || mask.contains(.delete) {
                        holder.source = nil
                        source.cancel()
                        arm(attempt: 0)
                    }
                }
                source.setCancelHandler { close(fd) }
                holder.source = source
                source.resume()
            }

            queue.async { arm(attempt: 0) }
            continuation.onTermination = { _ in
                queue.async {
                    holder.source?.cancel()
                    holder.source = nil
                }
            }
        }
    }
}
