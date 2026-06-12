//
//  AgentProcessScanner.swift
//  Kwota
//
//  Snapshots agent-related processes (claude / codex / antigravity backends)
//  via `ps`, for the Awake tab's "Agent Processes" section. Stateless: the
//  ViewModel owns the snapshot and keeps the previous one when scan()
//  returns nil (ps failure).
//
//  ps runs through a @Sendable runner closure rather than holding a
//  ProcessLauncher directly — the target's default MainActor isolation
//  means the OffMain.run body must only capture Sendable values.
//

import Foundation

final class AgentProcessScanner {
    typealias PSRunner = @Sendable () throws -> ProcessResult
    /// Batch cwd lookup for the matched pids (lsof). Best-effort: a throw or
    /// nonzero exit just leaves rows without a working directory.
    typealias CWDRunner = @Sendable ([Int32]) throws -> ProcessResult

    private let runPS: PSRunner
    private let runCWD: CWDRunner
    private let selfPID: Int32

    init(
        runPS: @escaping PSRunner = AgentProcessScanner.defaultPSRunner,
        runCWD: @escaping CWDRunner = AgentProcessScanner.defaultCWDRunner,
        selfPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)
    ) {
        self.runPS = runPS
        self.runCWD = runCWD
        self.selfPID = selfPID
    }

    /// Default runner: `ps -xww -o pid=,ppid=,pcpu=,etime=,tty=,args=`.
    /// `=` suppresses headers; `-ww` prevents arg truncation. `-x` (without
    /// `-a`) lists only the current user's processes, terminal-less included
    /// — other users' agent sessions must not appear as killable rows.
    nonisolated static func defaultPSRunner() throws -> ProcessResult {
        try SystemProcessLauncher().run(
            executable: "/bin/ps",
            arguments: ["-xww", "-o", "pid=,ppid=,pcpu=,etime=,tty=,args="],
            environment: nil
        )
    }

    /// One lsof spawn per scan tick for ALL matched pids (comma list), not
    /// one per pid — the list is small (~15) and the tick runs only while
    /// the Awake tab is visible.
    nonisolated static func defaultCWDRunner(pids: [Int32]) throws -> ProcessResult {
        try SystemProcessLauncher().run(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-d", "cwd", "-p", pids.map(String.init).joined(separator: ","), "-Fn"],
            environment: nil
        )
    }

    /// nil on ps failure — caller keeps its previous snapshot.
    func scan() async -> [AgentProcessInfo]? {
        let runPS = self.runPS
        let runCWD = self.runCWD
        let selfPID = self.selfPID
        let procs: [AgentProcessInfo]? = await OffMain.run {
            guard let result = try? runPS(), result.exitCode == 0 else { return nil }
            var procs = Self.parse(psOutput: result.stdout, selfPID: selfPID)
            guard !procs.isEmpty else { return procs }
            // Best-effort enrichment; lsof can fail (permissions, raced
            // exits) without invalidating the snapshot.
            if let cwdResult = try? runCWD(procs.map(\.pid)), cwdResult.exitCode == 0 {
                let cwds = Self.parseCWDs(lsofOutput: cwdResult.stdout)
                for i in procs.indices {
                    procs[i].workingDirectory = cwds[procs[i].pid]
                }
            }
            return procs
        }
        if procs == nil {
            AppLog.shared.log("AgentProcessScanner: ps failed", level: .warn)
        }
        return procs
    }

    // MARK: - Pure parsing (unit-test surface)

    /// Each line: pid ppid pcpu etime tty args… — first five fields are
    /// whitespace-delimited; everything after is the command line (which
    /// may itself contain spaces, so split with maxSplits: 5).
    nonisolated static func parse(psOutput: String, selfPID: Int32) -> [AgentProcessInfo] {
        psOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  let cpu = Double(fields[2])
            else { return nil }
            guard pid != selfPID else { return nil }
            let args = String(fields[5])
            guard let provider = classify(args: args) else { return nil }
            let tty = String(fields[4])
            return AgentProcessInfo(
                pid: pid,
                ppid: ppid,
                provider: provider,
                commandDisplay: displayName(args: args, provider: provider),
                cpuPercent: cpu,
                elapsed: String(fields[3]),
                tty: tty == "??" ? nil : tty
            )
        }
    }

    /// `lsof -Fn` emits `p<pid>` then `n<path>` per process; other field
    /// prefixes (e.g. `fcwd`) are ignored.
    nonisolated static func parseCWDs(lsofOutput: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var currentPID: Int32?
        for line in lsofOutput.split(separator: "\n") {
            if line.hasPrefix("p"), let pid = Int32(line.dropFirst()) {
                currentPID = pid
            } else if line.hasPrefix("n"), let pid = currentPID, result[pid] == nil {
                result[pid] = String(line.dropFirst())
            }
        }
        return result
    }

    /// nil = not an agent process. Exclusions run first: the Antigravity
    /// Electron UI helpers contain "Antigravity" in their path and would
    /// otherwise leak through the language_server rule.
    nonisolated static func classify(args: String) -> ProviderID? {
        if args.contains("Antigravity Helper") { return nil }
        let first = args.split(separator: " ").first.map(String.init) ?? ""
        let base = first.components(separatedBy: "/").last ?? ""
        if base == "claude" { return .claude }
        if base == "codex" || codexScriptMarkers.contains(where: args.contains) { return .codex }
        if base == "agy" { return .antigravity }
        // Dual condition: Windsurf/Codeium ship the same language_server
        // binary name; require an Antigravity.app path in the args.
        if base.hasPrefix("language_server"), args.contains("Antigravity") { return .antigravity }
        return nil
    }

    /// Node-hosted codex tooling — argv[0] is "node", so these only match by
    /// an args marker. The app-server broker detaches to ppid 1 by design;
    /// matching it makes genuine orphan brokers visible in the list.
    nonisolated private static let codexScriptMarkers = [
        "codex-companion.mjs",
        "app-server-broker.mjs",
    ]

    /// Row label: executable basename plus first non-flag argument
    /// ("codex app-server"), flags dropped ("claude"). Node-hosted codex
    /// scripts show the script name, not "node".
    nonisolated static func displayName(args: String, provider: ProviderID) -> String {
        if let marker = codexScriptMarkers.first(where: args.contains) { return marker }
        let tokens = args.split(separator: " ")
        let base = (tokens.first.map(String.init) ?? "").components(separatedBy: "/").last ?? ""
        if tokens.count > 1, !tokens[1].hasPrefix("-") {
            return "\(base) \(tokens[1])"
        }
        return base
    }
}

// MARK: - Kill seam

enum AgentProcessKillResult: Equatable {
    case terminated
    case alreadyGone        // ESRCH — raced with natural exit; success for callers
    case permissionDenied   // EPERM
    case failed(errno: Int32)
}

protocol AgentProcessKilling {
    func terminate(pid: Int32) -> AgentProcessKillResult
}

/// SIGTERM via kill(2). Syscall and errno read are injected so the errno
/// mapping is unit-testable without real processes.
struct SystemAgentProcessKiller: AgentProcessKilling {
    var killSyscall: (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) }
    var currentErrno: () -> Int32 = { errno }

    func terminate(pid: Int32) -> AgentProcessKillResult {
        // Hard floor at the syscall boundary: kill(0,·) signals the caller's
        // own process group, kill(1,·) launchd, negatives whole groups. No
        // legitimate target is ever ≤ 1, regardless of what upstream parsing
        // produced.
        guard pid > 1 else { return .failed(errno: EINVAL) }
        guard killSyscall(pid, SIGTERM) != 0 else { return .terminated }
        switch currentErrno() {
        case ESRCH: return .alreadyGone
        case EPERM: return .permissionDenied
        case let e: return .failed(errno: e)
        }
    }
}
