//
//  AgentProcessScannerTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class AgentProcessScannerTests: XCTestCase {

    // MARK: - parse: fixtures

    /// Realistic `ps -axww -o pid=,ppid=,pcpu=,etime=,tty=,args=` output.
    /// Covers: orphan codex, live claude with flag args, day-format etime,
    /// Antigravity language_server, foreign (Codeium) language_server,
    /// Antigravity Electron helper, node-hosted codex-companion, and a
    /// non-agent process. `??` = no controlling terminal (background).
    private let fixture = """
      4821     1   0.2 02:13:45 ??       /opt/homebrew/bin/codex app-server
      9210   812   1.4    22:11 ttys066  /Users/hau/.claude/local/claude --resume abc123
      1203     1   0.0 3-01:22:33 ??       /Applications/Antigravity.app/Contents/Resources/app/extensions/bin/language_server_macos_arm --serve
      3333     1   0.0    10:00 ??       /usr/local/bin/language_server_macos_arm --codeium
       544     1   0.0    01:02 ??       /Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/Contents/MacOS/Antigravity Helper --type=utility
      7777   500   0.0    05:00 ??       node /Users/hau/.codex/plugins/codex-companion.mjs --port 1234
      8888     1   0.0    00:30 ??       /usr/sbin/cupsd -l
    """

    func test_parse_matchesAgentProcessesOnly() {
        let procs = AgentProcessScanner.parse(psOutput: fixture, selfPID: 99999)
        XCTAssertEqual(procs.map(\.pid), [4821, 9210, 1203, 7777])
    }

    func test_parse_extractsFields() {
        let procs = AgentProcessScanner.parse(psOutput: fixture, selfPID: 99999)
        let codex = procs[0]
        XCTAssertEqual(codex.pid, 4821)
        XCTAssertEqual(codex.ppid, 1)
        XCTAssertEqual(codex.provider, .codex)
        XCTAssertEqual(codex.cpuPercent, 0.2, accuracy: 0.001)
        XCTAssertEqual(codex.elapsed, "02:13:45")
        XCTAssertTrue(codex.isOrphan)
    }

    func test_parse_ttyExtracted() {
        let procs = AgentProcessScanner.parse(psOutput: fixture, selfPID: 99999)
        XCTAssertNil(procs[0].tty, "?? means no controlling terminal")
        XCTAssertEqual(procs[1].tty, "ttys066")
    }

    // MARK: - parseCWDs (lsof -Fn batch output)

    func test_parseCWDs_mapsPidToPath() {
        let out = """
        p4821
        n/Users/hau/SideProjects/kwota
        p9210
        n/Users/hau/SideProjects/kashback-system
        """
        let map = AgentProcessScanner.parseCWDs(lsofOutput: out)
        XCTAssertEqual(map[4821], "/Users/hau/SideProjects/kwota")
        XCTAssertEqual(map[9210], "/Users/hau/SideProjects/kashback-system")
    }

    func test_parseCWDs_ignoresOtherFieldLines() {
        let out = "p4821\nfcwd\nn/tmp\ngarbage\n"
        XCTAssertEqual(AgentProcessScanner.parseCWDs(lsofOutput: out), [4821: "/tmp"])
    }

    func test_parse_dayFormatEtimeKeptRaw() {
        let procs = AgentProcessScanner.parse(psOutput: fixture, selfPID: 99999)
        XCTAssertEqual(procs[2].elapsed, "3-01:22:33")
    }

    func test_parse_liveClaudeIsNotOrphan() {
        let procs = AgentProcessScanner.parse(psOutput: fixture, selfPID: 99999)
        let claude = procs[1]
        XCTAssertEqual(claude.provider, .claude)
        XCTAssertEqual(claude.ppid, 812)
        XCTAssertFalse(claude.isOrphan)
    }

    func test_parse_excludesSelfPID() {
        let procs = AgentProcessScanner.parse(psOutput: fixture, selfPID: 4821)
        XCTAssertFalse(procs.contains { $0.pid == 4821 })
    }

    func test_parse_ignoresMalformedLines() {
        let garbage = "not a ps line\n  12 only-two\n"
        XCTAssertTrue(AgentProcessScanner.parse(psOutput: garbage, selfPID: 1).isEmpty)
    }

    // MARK: - classify

    func test_classify_foreignLanguageServerExcluded() {
        // language_server binary whose args never mention Antigravity (e.g.
        // Windsurf/Codeium ships the same binary name) must not match.
        XCTAssertNil(AgentProcessScanner.classify(
            args: "/usr/local/bin/language_server_macos_arm --codeium"))
    }

    func test_classify_antigravityHelperExcluded() {
        XCTAssertNil(AgentProcessScanner.classify(
            args: "/Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/Contents/MacOS/Antigravity Helper --type=utility"))
    }

    func test_classify_agyCLIMatches() {
        XCTAssertEqual(AgentProcessScanner.classify(args: "/opt/homebrew/bin/agy chat"), .antigravity)
    }

    func test_classify_codexCompanionViaArgs() {
        XCTAssertEqual(AgentProcessScanner.classify(
            args: "node /Users/hau/.codex/plugins/codex-companion.mjs --port 1234"), .codex)
    }

    func test_classify_codexBrokerViaArgs() {
        // The plugin broker detaches by design (ppid 1) and runs under node,
        // so the codex basename rule never sees it — args marker must match.
        XCTAssertEqual(AgentProcessScanner.classify(
            args: "/opt/homebrew/Cellar/node/26.0.0/bin/node /Users/hau/.claude/plugins/cache/openai-codex/codex/1.0.4/scripts/app-server-broker.mjs serve"), .codex)
    }

    // MARK: - displayName

    func test_displayName_codexKeepsSubcommand() {
        XCTAssertEqual(AgentProcessScanner.displayName(
            args: "/opt/homebrew/bin/codex app-server", provider: .codex),
            "codex app-server")
    }

    func test_displayName_flagArgsDropped() {
        XCTAssertEqual(AgentProcessScanner.displayName(
            args: "/Users/hau/.claude/local/claude --resume abc123", provider: .claude),
            "claude")
    }

    func test_displayName_companionShowsScriptName() {
        XCTAssertEqual(AgentProcessScanner.displayName(
            args: "node /Users/hau/.codex/plugins/codex-companion.mjs --port 1234", provider: .codex),
            "codex-companion.mjs")
    }

    func test_displayName_brokerShowsScriptName() {
        XCTAssertEqual(AgentProcessScanner.displayName(
            args: "node /Users/hau/.claude/plugins/cache/openai-codex/codex/1.0.4/scripts/app-server-broker.mjs serve", provider: .codex),
            "app-server-broker.mjs")
    }

    // MARK: - scan() async path

    func test_scan_success_returnsParsedRows() async {
        let scanner = AgentProcessScanner(
            runPS: { ProcessResult(
                stdout: "  4821     1   0.2 02:13:45 ??       /opt/homebrew/bin/codex app-server\n",
                stderr: "", exitCode: 0) },
            selfPID: 99999
        )
        let rows = await scanner.scan()
        XCTAssertEqual(rows?.map(\.pid), [4821])
    }

    func test_scan_enrichesWorkingDirectory() async {
        let scanner = AgentProcessScanner(
            runPS: { ProcessResult(
                stdout: "  4821     1   0.2 02:13:45 ??       /opt/homebrew/bin/codex app-server\n",
                stderr: "", exitCode: 0) },
            runCWD: { pids in
                XCTAssertEqual(pids, [4821])
                return ProcessResult(stdout: "p4821\nn/Users/hau/SideProjects/kwota\n",
                                     stderr: "", exitCode: 0)
            },
            selfPID: 99999
        )
        let rows = await scanner.scan()
        XCTAssertEqual(rows?.first?.workingDirectory, "/Users/hau/SideProjects/kwota")
    }

    func test_scan_cwdFailure_leavesRowsWithoutDirectory() async {
        struct Boom: Error {}
        let scanner = AgentProcessScanner(
            runPS: { ProcessResult(
                stdout: "  4821     1   0.2 02:13:45 ??       /opt/homebrew/bin/codex app-server\n",
                stderr: "", exitCode: 0) },
            runCWD: { _ in throw Boom() },
            selfPID: 99999
        )
        let rows = await scanner.scan()
        XCTAssertEqual(rows?.map(\.pid), [4821], "cwd lookup is best-effort, never fatal")
        XCTAssertNil(rows?.first?.workingDirectory)
    }

    func test_scan_nonzeroExit_returnsNil() async {
        let scanner = AgentProcessScanner(
            runPS: { ProcessResult(stdout: "", stderr: "boom", exitCode: 1) },
            selfPID: 99999
        )
        let rows = await scanner.scan()
        XCTAssertNil(rows)
    }

    func test_scan_throwingRunner_returnsNil() async {
        struct Boom: Error {}
        let scanner = AgentProcessScanner(runPS: { throw Boom() }, selfPID: 99999)
        let rows = await scanner.scan()
        XCTAssertNil(rows)
    }

    // MARK: - SystemAgentProcessKiller errno mapping

    func test_killer_zeroReturn_terminated() {
        let killer = SystemAgentProcessKiller(
            killSyscall: { _, _ in 0 }, currentErrno: { 0 })
        XCTAssertEqual(killer.terminate(pid: 123), .terminated)
    }

    func test_killer_esrch_alreadyGone() {
        let killer = SystemAgentProcessKiller(
            killSyscall: { _, _ in -1 }, currentErrno: { ESRCH })
        XCTAssertEqual(killer.terminate(pid: 123), .alreadyGone)
    }

    func test_killer_eperm_permissionDenied() {
        let killer = SystemAgentProcessKiller(
            killSyscall: { _, _ in -1 }, currentErrno: { EPERM })
        XCTAssertEqual(killer.terminate(pid: 123), .permissionDenied)
    }

    func test_killer_otherErrno_failed() {
        let killer = SystemAgentProcessKiller(
            killSyscall: { _, _ in -1 }, currentErrno: { EINVAL })
        XCTAssertEqual(killer.terminate(pid: 123), .failed(errno: EINVAL))
    }

    func test_killer_rejectsNonPositiveAndLaunchdPIDs() {
        // kill(0,·) signals the caller's own process group, kill(1,·)
        // launchd, negatives whole groups — the syscall must never fire.
        var called = false
        let killer = SystemAgentProcessKiller(
            killSyscall: { _, _ in called = true; return 0 },
            currentErrno: { 0 })
        XCTAssertEqual(killer.terminate(pid: 0), .failed(errno: EINVAL))
        XCTAssertEqual(killer.terminate(pid: 1), .failed(errno: EINVAL))
        XCTAssertEqual(killer.terminate(pid: -5), .failed(errno: EINVAL))
        XCTAssertFalse(called, "guard must reject before the syscall")
    }

    func test_killer_sendsSIGTERM() {
        var sent: (pid: Int32, sig: Int32)?
        let killer = SystemAgentProcessKiller(
            killSyscall: { pid, sig in sent = (pid, sig); return 0 },
            currentErrno: { 0 })
        _ = killer.terminate(pid: 4821)
        XCTAssertEqual(sent?.pid, 4821)
        XCTAssertEqual(sent?.sig, SIGTERM)
    }
}
