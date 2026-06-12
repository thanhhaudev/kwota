//
//  AgentProcessScannerTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class AgentProcessScannerTests: XCTestCase {

    // MARK: - parse: fixtures

    /// Realistic `ps -axww -o pid=,ppid=,pcpu=,etime=,args=` output.
    /// Covers: orphan codex, live claude with flag args, day-format etime,
    /// Antigravity language_server, foreign (Codeium) language_server,
    /// Antigravity Electron helper, node-hosted codex-companion, and a
    /// non-agent process.
    private let fixture = """
      4821     1   0.2 02:13:45 /opt/homebrew/bin/codex app-server
      9210   812   1.4    22:11 /Users/hau/.claude/local/claude --resume abc123
      1203     1   0.0 3-01:22:33 /Applications/Antigravity.app/Contents/Resources/app/extensions/bin/language_server_macos_arm --serve
      3333     1   0.0    10:00 /usr/local/bin/language_server_macos_arm --codeium
       544     1   0.0    01:02 /Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/Contents/MacOS/Antigravity Helper --type=utility
      7777   500   0.0    05:00 node /Users/hau/.codex/plugins/codex-companion.mjs --port 1234
      8888     1   0.0    00:30 /usr/sbin/cupsd -l
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

    // MARK: - scan() async path

    func test_scan_success_returnsParsedRows() async {
        let scanner = AgentProcessScanner(
            runPS: { ProcessResult(
                stdout: "  4821     1   0.2 02:13:45 /opt/homebrew/bin/codex app-server\n",
                stderr: "", exitCode: 0) },
            selfPID: 99999
        )
        let rows = await scanner.scan()
        XCTAssertEqual(rows?.map(\.pid), [4821])
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
