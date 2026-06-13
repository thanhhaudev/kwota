//
//  HermeticStatsStore.swift
//  KwotaTests
//
//  Free helper used by every MenuBarViewModel fixture to ensure test runs
//  never read real ~/.claude data or write a real stats-ledger.json.
//

import Foundation
@testable import Kwota

/// Returns a `StatsStore` that is safe to use in unit tests:
/// - `FakeJSONLogReader` → never reads real `~/.claude`
/// - `/dev/null` ledgerURL → persist writes fail silently (no real
///   `stats-ledger.json` is created)
/// - `persistDebounce: 0` → no background timer lingers after the test ends
@MainActor
func makeHermeticStatsStore() -> StatsStore {
    StatsStore(
        reader: FakeJSONLogReader(),
        ledgerURL: URL(fileURLWithPath: "/dev/null"),
        persistDebounce: 0
    )
}
