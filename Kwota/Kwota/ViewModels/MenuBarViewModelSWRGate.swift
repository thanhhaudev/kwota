//
//  MenuBarViewModelSWRGate.swift
//  Kwota
//
//  Pure stale-while-revalidate predicate consumed by MenuBarViewModel's
//  opportunistic refresh triggers (popoverDidOpen and any future
//  non-user-driven entry point). Returns true when the caller should
//  skip a fetch because the active `summary` is still fresh.
//
//  Why a separate type: keeps the decision testable as a pure function,
//  free of MenuBarViewModel's actor-isolation and stored-state setup.
//  The signature carries `isManual` so future call sites (e.g. a generic
//  refresh dispatcher) can route through this helper unchanged.
//

import Foundation

enum MenuBarViewModelSWRGate {
    /// Returns true when the opportunistic caller should skip refresh.
    ///
    /// - `fetchedAt`: timestamp of the most recent successful summary.
    ///   `nil` means no prior fetch — always refresh.
    /// - `window`: skip iff `now - fetchedAt < window`. Boundary
    ///   (`==`) does not skip — strict less-than so the periodic 60s
    ///   tick scheduled at the same cadence does not racily get
    ///   suppressed by an immediately-prior fetch.
    /// - `isManual`: a user-initiated Refresh tap. Always refresh,
    ///   regardless of how fresh the cache is.
    static func shouldSkipRefresh(
        fetchedAt: Date?,
        now: Date,
        window: TimeInterval,
        isManual: Bool
    ) -> Bool {
        if isManual { return false }
        guard let fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) < window
    }
}
