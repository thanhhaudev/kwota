//
//  OffMain.swift
//  Kwota
//

import Foundation

/// Runs synchronous, blocking work off the main thread.
///
/// This target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an
/// unannotated closure — including the body of `Task.detached { ... }` — is
/// `@MainActor` by default and executes ON the main thread. `Task.detached`
/// therefore does NOT move synchronous work off main, and detached tasks have
/// also been observed to never get scheduled under sustained MainActor load
/// (see `AntigravityProcessWatcher`). Bridging through a GCD global queue is
/// what reliably leaves the main thread — the same approach `pokeNow()` uses.
///
/// Use this for one-shot blocking IO: filesystem walks, subprocess reads,
/// size computations. Work that must be *serialized* across calls (e.g. a
/// reader holding mutable cursor state) keeps its own serial queue instead —
/// a shared concurrent pool would let those calls race.
enum OffMain {
    /// Awaits `work` running on a background (utility-QoS by default) GCD queue.
    nonisolated static func run<T: Sendable>(
        qos: DispatchQoS.QoSClass = .utility,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Throwing variant — rethrows whatever `work` throws.
    nonisolated static func run<T: Sendable>(
        qos: DispatchQoS.QoSClass = .utility,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
