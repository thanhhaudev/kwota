//
//  AgentProcessInfo.swift
//  Kwota
//
//  One agent-related process from a `ps` snapshot. "Orphan" means the
//  original parent died and launchd adopted the process (ppid == 1) —
//  e.g. a `codex app-server` broker left over from a closed worktree
//  session. Orphans are the only rows the UI lets the user kill.
//

import Foundation

struct AgentProcessInfo: Identifiable, Equatable {
    let pid: Int32
    let ppid: Int32
    let provider: ProviderID
    /// Basename plus subcommand for the row label, e.g. "codex app-server".
    let commandDisplay: String
    let cpuPercent: Double
    /// Raw `ps` etime — "MM:SS", "HH:MM:SS", or "D-HH:MM:SS". Display-only.
    let elapsed: String

    var isOrphan: Bool { ppid == 1 }
    var id: Int32 { pid }
}
