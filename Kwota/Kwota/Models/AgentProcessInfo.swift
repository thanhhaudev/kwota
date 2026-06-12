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

    /// CPU% mapped to a coarse activity bucket. Thresholds are hand-picked:
    /// agent CLIs idle near 0%, sit well under 30% while streaming, and only
    /// pass it on heavy tool runs. The bucket — not the raw % — is also the
    /// list's sort key, so rows don't reshuffle on every poll tick as CPU
    /// readings wobble. Display strings/colors live in the view layer.
    enum ActivityTier: Int, Comparable {
        case idle, active, busy

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var activityTier: ActivityTier {
        if cpuPercent < 2 { return .idle }
        if cpuPercent < 30 { return .active }
        return .busy
    }
}
