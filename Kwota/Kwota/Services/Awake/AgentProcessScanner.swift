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

    private let runPS: PSRunner
    private let selfPID: Int32

    init(
        runPS: @escaping PSRunner = AgentProcessScanner.defaultPSRunner,
        selfPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)
    ) {
        self.runPS = runPS
        self.selfPID = selfPID
    }

    /// Default runner: `ps -axww -o pid=,ppid=,pcpu=,etime=,args=`.
    /// `=` suppresses headers; `-ww` prevents arg truncation.
    nonisolated static func defaultPSRunner() throws -> ProcessResult {
        try SystemProcessLauncher().run(
            executable: "/bin/ps",
            arguments: ["-axww", "-o", "pid=,ppid=,pcpu=,etime=,args="],
            environment: nil
        )
    }

    /// nil on ps failure — caller keeps its previous snapshot.
    func scan() async -> [AgentProcessInfo]? {
        let runPS = self.runPS
        let result = try? await OffMain.run { try runPS() }
        guard let result, result.exitCode == 0 else {
            AppLog.shared.log("AgentProcessScanner: ps failed", level: .warn)
            return nil
        }
        return Self.parse(psOutput: result.stdout, selfPID: selfPID)
    }

    // MARK: - Pure parsing (unit-test surface)

    /// Each line: pid ppid pcpu etime args… — first four fields are
    /// whitespace-delimited; everything after is the command line (which
    /// may itself contain spaces, so split with maxSplits: 4).
    nonisolated static func parse(psOutput: String, selfPID: Int32) -> [AgentProcessInfo] {
        psOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  let cpu = Double(fields[2])
            else { return nil }
            guard pid != selfPID else { return nil }
            let args = String(fields[4])
            guard let provider = classify(args: args) else { return nil }
            return AgentProcessInfo(
                pid: pid,
                ppid: ppid,
                provider: provider,
                commandDisplay: displayName(args: args, provider: provider),
                cpuPercent: cpu,
                elapsed: String(fields[3])
            )
        }
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
        guard killSyscall(pid, SIGTERM) != 0 else { return .terminated }
        switch currentErrno() {
        case ESRCH: return .alreadyGone
        case EPERM: return .permissionDenied
        case let e: return .failed(errno: e)
        }
    }
}
