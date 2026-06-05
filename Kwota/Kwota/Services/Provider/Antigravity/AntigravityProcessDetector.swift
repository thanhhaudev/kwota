//
//  AntigravityProcessDetector.swift
//  Kwota
//
//  Finds the running Antigravity language_server process and extracts the
//  CSRF token + listening ports needed to query its local Connect-RPC
//  endpoint. Discovery flow per ma-do-ka/Antigravity-Quota-Monitor (MIT) and
//  leonanramosvieira/AntigravityQuotaWatcher (Apache-2.0):
//    1. ps -ww -eo pid,args | grep language_server
//    2. parse --csrf_token + --app_data_dir antigravity
//    3. lsof -Pan -p <PID> -i | grep LISTEN
//    4. return [PID, csrfToken, ports[]]
//

import Foundation

struct AntigravityProcessInfo: Equatable {
    let pid: Int32
    let csrfToken: String
    /// All TCP ports the language_server is listening on. The caller
    /// (AntigravityAPIClient) probes each to find the working RPC port.
    let listeningPorts: [Int]
}

/// Explicitly nonisolated because the project uses `-default-isolation=MainActor`
/// (Swift 6 module-wide default). Without this, every method on this class
/// would be MainActor-isolated, and `detect()` would hop to MainActor at every
/// await — observable as the watcher's baseline task hanging while SwiftUI's
/// runloop is busy. Process spawning and lsof parsing don't need MainActor.
nonisolated final class AntigravityProcessDetector {
    typealias ShellRunner = (_ command: String, _ args: [String]) throws -> String

    static let csrfTokenRegex = try! NSRegularExpression(
        pattern: #"--csrf_token\s+([a-fA-F0-9-]+)"#)
    static let antigravityArgvHint = "--app_data_dir antigravity"

    let runShell: ShellRunner
    /// Test-only override. When non-nil, `detect()` invokes this directly
    /// and skips the shell/parse pipeline. Used by AntigravityProcessWatcher's
    /// closure-based test initializer.
    private let detectOverride: (@Sendable () throws -> AntigravityProcessInfo?)?

    init(
        runShell: @escaping ShellRunner = AntigravityProcessDetector.defaultShellRunner,
        detectOverride: (@Sendable () throws -> AntigravityProcessInfo?)? = nil
    ) {
        self.runShell = runShell
        self.detectOverride = detectOverride
    }

    /// Returns nil when no Antigravity language_server is running. Throws
    /// only if the shell commands themselves fail unexpectedly.
    ///
    /// Synchronous on purpose. The async version with `Process` +
    /// `withCheckedThrowingContinuation` deadlocked in production
    /// (await detector.detect() from a Task.detached body never
    /// resumed past entry — root cause never fully pinned). The shell runner
    /// is synchronous + drains the pipe concurrently; it runs in <~10ms here
    /// (a targeted `pgrep` + a per-pid `ps` + one `lsof`). The watcher's
    /// `try detector.detect()` works from any context.
    ///
    /// Discovery is targeted, not a full process scan: `pgrep -f language_server`
    /// yields candidate PIDs, then `ps -ww -o pid,args -p <pids>` fetches argv
    /// for just those. This is ~10x cheaper than `ps -ww -eo pid,args` (all
    /// processes) and feeds the unchanged `parseProcess` (a header/extra row is
    /// skipped because it lacks the `--app_data_dir antigravity` hint).
    ///
    /// All shell calls go through the injected `runShell` so tests can stub
    /// them; `detectOverride` short-circuits the whole pipeline for tests that
    /// supply a canned `AntigravityProcessInfo`.
    nonisolated func detect() throws -> AntigravityProcessInfo? {
        if let detectOverride { return try detectOverride() }
        let pgrepOut = try runShell("/usr/bin/pgrep", ["-f", "language_server"])
        let pids = Self.parsePIDs(pgrepOut)
        guard !pids.isEmpty else { return nil }
        let pidList = pids.map(String.init).joined(separator: ",")
        let psOutput = try runShell("/bin/ps", ["-ww", "-o", "pid,args", "-p", pidList])
        guard let (pid, csrfToken) = parseProcess(psOutput) else {
            return nil
        }
        let lsofOutput: String
        do {
            lsofOutput = try runShell("/usr/sbin/lsof", ["-Pan", "-p", "\(pid)", "-i"])
        } catch {
            return AntigravityProcessInfo(pid: pid, csrfToken: csrfToken, listeningPorts: [])
        }
        let ports = parsePorts(lsofOutput)
        return AntigravityProcessInfo(pid: pid, csrfToken: csrfToken, listeningPorts: ports)
    }

    /// Default synchronous shell runner — the production implementation of the
    /// injectable `runShell` seam. Synchronous (not the prior async
    /// `withCheckedThrowingContinuation` version) because that deadlocked when
    /// called from a Task.detached body under `-default-isolation=MainActor`
    /// (async continuations pulled onto MainActor at every suspension point).
    /// Draining the pipe concurrently is the reliable path.
    ///
    /// Returns stdout regardless of exit status (does NOT throw on non-zero) —
    /// `pgrep` exits 1 with empty stdout when nothing matches, which the caller
    /// treats as "no process."
    ///
    /// The `readabilityHandler` drain is critical — process output can exceed
    /// the 64KB Pipe buffer; waiting until exit before reading would block the
    /// child writing stdout and hang `waitUntilExit()` forever.
    nonisolated static func defaultShellRunner(_ command: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        // Buffer via a class instance + NSLock so the readabilityHandler
        // closure (runs on a separate dispatch queue) can mutate without
        // triggering Swift 6's `Mutation of captured var in concurrently-
        // executing code` error.
        final class Buffer { var data = Data() }
        let buffer = Buffer()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            lock.lock(); buffer.data.append(chunk); lock.unlock()
        }
        try p.run()
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.availableData
        lock.lock()
        if !tail.isEmpty { buffer.data.append(tail) }
        let out = buffer.data
        lock.unlock()
        return String(data: out, encoding: .utf8) ?? ""
    }


    /// Pure parser. Public for tests.
    static func parseProcess(_ psOutput: String) -> (pid: Int32, csrfToken: String)? {
        for line in psOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  trimmed.contains("language_server"),
                  trimmed.contains(Self.antigravityArgvHint)
            else { continue }
            // First field is PID (ps right-pads the pid column with spaces);
            // everything after the first whitespace is argv.
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let argv = String(parts[1])
            let nsArgv = argv as NSString
            let match = Self.csrfTokenRegex.firstMatch(
                in: argv, range: NSRange(location: 0, length: nsArgv.length))
            guard let match, match.numberOfRanges >= 2 else { continue }
            let csrf = nsArgv.substring(with: match.range(at: 1))
            return (pid, csrf)
        }
        return nil
    }

    /// Instance-method overload so `detect()` can dispatch through `self`.
    /// Identical behavior to the static parser; provided for symmetry with
    /// dependency-injection-style tests that need an instance.
    func parseProcess(_ psOutput: String) -> (pid: Int32, csrfToken: String)? {
        Self.parseProcess(psOutput)
    }

    /// Pure parser. Public for tests.
    static func parsePorts(_ lsofOutput: String) -> [Int] {
        var ports: Set<Int> = []
        for line in lsofOutput.components(separatedBy: "\n") {
            guard line.contains("LISTEN") else { continue }
            // Match `127.0.0.1:NNNNN`. Skip lines like
            // `127.0.0.1:49838->127.0.0.1:55000 (ESTABLISHED)` because the
            // `LISTEN` check already filtered them out.
            if let r = line.range(of: #"127\.0\.0\.1:(\d+)"#, options: .regularExpression) {
                let m = String(line[r])
                if let colon = m.lastIndex(of: ":"),
                   let port = Int(m[m.index(after: colon)...]) {
                    ports.insert(port)
                }
            }
        }
        return ports.sorted()
    }

    func parsePorts(_ lsofOutput: String) -> [Int] {
        Self.parsePorts(lsofOutput)
    }

    /// Pure parser for `pgrep` output (one PID per line) → PIDs. Public for tests.
    static func parsePIDs(_ output: String) -> [Int32] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}
