//
//  AgentProcessInfo.swift
//  Kwota
//
//  One agent-related process from a `ps` snapshot. `isOrphan` is the raw
//  ppid==1 signal (launchd adopted the process); whether that actually
//  means "abandoned" is decided per-snapshot by AgentProcessOrphanPolicy —
//  codex's node helpers detach to ppid 1 by design. Every row is killable;
//  the inline confirm is the safety gate.
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
    /// Controlling terminal ("ttys016") or nil for `??` — nil distinguishes
    /// editor-spawned agent servers (e.g. Zed Agent Panel) from terminal
    /// sessions, which otherwise render as identical "claude" rows.
    var tty: String? = nil
    /// Working directory from a best-effort lsof batch lookup; the row shows
    /// its basename so look-alike claude sessions become attributable to
    /// their projects.
    var workingDirectory: String? = nil

    var isOrphan: Bool { ppid == 1 }
    var id: Int32 { pid }
    var projectName: String? {
        workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}
