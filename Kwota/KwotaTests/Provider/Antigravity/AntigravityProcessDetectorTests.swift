import XCTest
@testable import Kwota

final class AntigravityProcessDetectorTests: XCTestCase {
    // MARK: - parseProcess

    func test_parseProcess_findsAntigravityProcess() {
        let line = "71236 70814 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --override_ide_name antigravity --subclient_type hub --override_ide_version 2.0.6 --override_user_agent_name antigravity --https_server_port 0 --csrf_token 278ef7a5-91a5-4fdd-af7e-387b849f1812 --app_data_dir antigravity --api_server_url https://generativelanguage.googleapis.com --cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com --enable_sidecars"
        let result = AntigravityProcessDetector.parseProcess(line)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pid, 71236)
        XCTAssertEqual(result?.csrfToken, "278ef7a5-91a5-4fdd-af7e-387b849f1812")
    }

    func test_parseProcess_returnsNilWhenNoLanguageServer() {
        let result = AntigravityProcessDetector.parseProcess("99 /bin/launchd")
        XCTAssertNil(result)
    }

    func test_parseProcess_ignoresGrepLine() {
        // grep line contains "language_server" but not "--app_data_dir antigravity"
        let result = AntigravityProcessDetector.parseProcess("99999 grep language_server")
        XCTAssertNil(result)
    }

    func test_parseProcess_distinguishesAntigravityFromOtherCodeium() {
        // Cursor's Cascade ships a similar language_server binary but with a different --app_data_dir.
        // The detector must pick the Antigravity line, not the Cursor one.
        let cursorLine = "50001 /Applications/Cursor.app/Contents/Resources/bin/language_server --standalone --csrf_token aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa --app_data_dir cursor --enable_sidecars"
        let antigravityLine = "71236 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --csrf_token 278ef7a5-91a5-4fdd-af7e-387b849f1812 --app_data_dir antigravity --enable_sidecars"
        let combined = [cursorLine, antigravityLine].joined(separator: "\n")
        let result = AntigravityProcessDetector.parseProcess(combined)
        XCTAssertEqual(result?.pid, 71236)
        XCTAssertEqual(result?.csrfToken, "278ef7a5-91a5-4fdd-af7e-387b849f1812")
    }

    // MARK: - parsePorts

    func test_parsePorts_extractsListenPorts() {
        let lsofOutput = """
        language_ 71236 haunguyen    6u  IPv4 0x736596c40a2f3760      0t0  TCP 127.0.0.1:49838 (LISTEN)
        language_ 71236 haunguyen    7u  IPv4 0x93f2830bf9c0e31a      0t0  TCP 127.0.0.1:49839 (LISTEN)
        """
        let ports = AntigravityProcessDetector.parsePorts(lsofOutput)
        XCTAssertEqual(ports, [49838, 49839])
    }

    func test_parsePorts_returnsEmptyWhenNoListenLines() {
        let lsofOutput = """
        language_ 71236 haunguyen   10u  IPv4 0xabc      0t0  TCP 127.0.0.1:49838->127.0.0.1:55000 (ESTABLISHED)
        language_ 71236 haunguyen   11u  IPv4 0xdef      0t0  TCP 127.0.0.1:49839->127.0.0.1:55001 (ESTABLISHED)
        """
        let ports = AntigravityProcessDetector.parsePorts(lsofOutput)
        XCTAssertEqual(ports, [])
    }

    // MARK: - parsePIDs

    func test_parsePIDs_parsesMultipleLines() {
        XCTAssertEqual(AntigravityProcessDetector.parsePIDs("71236\n71240\n"), [71236, 71240])
    }

    func test_parsePIDs_returnsEmptyForEmptyOutput() {
        XCTAssertEqual(AntigravityProcessDetector.parsePIDs(""), [])
    }

    func test_parsePIDs_trimsWhitespaceAndSkipsBlankLines() {
        XCTAssertEqual(AntigravityProcessDetector.parsePIDs("  71236  \n\n"), [71236])
    }

    func test_parsePIDs_skipsNonNumericLines() {
        XCTAssertEqual(AntigravityProcessDetector.parsePIDs("notapid\n71236"), [71236])
    }

    // MARK: - detect() integration

    func test_detect_integration_withInjectedRunner() throws {
        let psOutput = "71236 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token 278ef7a5-91a5-4fdd-af7e-387b849f1812 --app_data_dir antigravity"
        let lsofOutput = """
        language_ 71236 haunguyen    6u  IPv4 0x1      0t0  TCP 127.0.0.1:49838 (LISTEN)
        language_ 71236 haunguyen    7u  IPv4 0x2      0t0  TCP 127.0.0.1:49839 (LISTEN)
        """
        let detector = AntigravityProcessDetector { command, args in
            switch command {
            case "/usr/bin/pgrep":
                XCTAssertEqual(args, ["-f", "language_server"])
                return "71236\n"
            case "/bin/ps":
                XCTAssertEqual(args, ["-ww", "-o", "pid,args", "-p", "71236"])
                return psOutput
            case "/usr/sbin/lsof":
                XCTAssertEqual(args, ["-Pan", "-p", "71236", "-i"])
                return lsofOutput
            default:
                XCTFail("Unexpected command: \(command)")
                return ""
            }
        }
        let info = try detector.detect()
        XCTAssertEqual(info?.pid, 71236)
        XCTAssertEqual(info?.csrfToken, "278ef7a5-91a5-4fdd-af7e-387b849f1812")
        XCTAssertEqual(info?.listeningPorts, [49838, 49839])
    }

    func test_detect_returnsNilWhenNoProcess() throws {
        // pgrep finds nothing → ps/lsof must never run, detect returns nil.
        let detector = AntigravityProcessDetector { command, _ in
            if command == "/usr/bin/pgrep" {
                return ""   // pgrep exits 1 with empty stdout when no match
            }
            XCTFail("ps/lsof should not be invoked when pgrep yields no PIDs")
            return ""
        }
        let info = try detector.detect()
        XCTAssertNil(info)
    }

    func test_detect_returnsNilWhenLsofFails() throws {
        // PID + CSRF parsing succeeded, so return a partial ProcessInfo with
        // empty ports rather than nil. Callers can still log/skip when ports
        // are empty.
        struct LsofError: Error {}
        let detector = AntigravityProcessDetector { command, _ in
            switch command {
            case "/usr/bin/pgrep":
                return "71236\n"
            case "/bin/ps":
                return "71236 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token 278ef7a5-91a5-4fdd-af7e-387b849f1812 --app_data_dir antigravity"
            case "/usr/sbin/lsof":
                throw LsofError()
            default:
                return ""
            }
        }
        let info = try detector.detect()
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.pid, 71236)
        XCTAssertEqual(info?.csrfToken, "278ef7a5-91a5-4fdd-af7e-387b849f1812")
        XCTAssertEqual(info?.listeningPorts, [])
    }
}
