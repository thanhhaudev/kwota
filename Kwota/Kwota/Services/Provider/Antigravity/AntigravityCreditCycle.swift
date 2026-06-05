//  AntigravityCreditCycle.swift
//  Kwota
//
//  Pure detection of an Antigravity AI-credit cycle reset.
//
//  An earlier version inferred resets from the utilization history
//  (`UsageHistoryEntry.sevenDay`). That was unsafe: utilization is
//  `wallet / tier.aiCreditsCeiling`, so a plan/ceiling change (denominator)
//  or a stale state.vscdb fallback balance (numerator) moves the ratio
//  without any real monthly reset, manufacturing a false "reset" drop.
//
//  This detector works on the RAW wallet balance against the previous
//  REAL-API reading, and only when the ceiling is unchanged — so neither a
//  ceiling change nor a fallback-sourced balance can masquerade as a reset.

import Foundation

/// One real-API credit reading: raw wallet balance against the tier ceiling.
/// "Real-API" means it came from `userTier.availableCredits`, never the
/// state.vscdb fallback (`aiCreditsFallback`), which can be stale.
struct CreditCycleReading: Equatable {
    let wallet: Int64
    let ceiling: Int64
}

/// The balance must have jumped up by at least this fraction of the ceiling
/// AND now sit at/above `creditResetFullFraction`. These mirror the prior
/// "40-point drop / ≤10% remaining" intent, expressed on raw fractions, so
/// a mid-cycle top-up that doesn't restore near-full is not a reset.
private let creditResetJumpFraction: Double = 0.40
private let creditResetFullFraction: Double = 0.90

/// Did a monthly credit reset just occur between `previous` and `current`?
/// True only when:
///   - there is a previous reading (no opinion on first observation),
///   - the ceiling is unchanged (a plan/ceiling change is NOT a reset),
///   - the balance jumped up by ≥ `creditResetJumpFraction` of the ceiling, and
///   - it now sits at ≥ `creditResetFullFraction` of the ceiling (near full).
func didCreditCycleReset(previous: CreditCycleReading?, current: CreditCycleReading) -> Bool {
    guard let previous,
          previous.ceiling == current.ceiling,
          current.ceiling > 0
    else { return false }
    let prevFraction = Double(previous.wallet) / Double(current.ceiling)
    let currentFraction = Double(current.wallet) / Double(current.ceiling)
    return currentFraction - prevFraction >= creditResetJumpFraction
        && currentFraction >= creditResetFullFraction
}
