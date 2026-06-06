//
//  CodexProbe.swift
//  Kwota
//

import Foundation

final class CodexProbe {
    private let launcher: ProcessLauncher

    init(launcher: ProcessLauncher = SystemProcessLauncher()) {
        self.launcher = launcher
    }

    func run() async throws -> ProbeResult {
        let path = ClaudeProbe.augmentedPATH(existing: ProcessInfo.processInfo.environment["PATH"] ?? "")
        let result = try launcher.run(
            executable: "/usr/bin/env",
            arguments: ["-S", "PATH=\(path)", "codex", "--version"],
            environment: nil
        )

        if result.exitCode == 0 {
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // Codex prints "codex-cli 0.137.0" — keep just the trailing version
            // token. For builds that print a bare "0.137.0" the single token
            // is preserved unchanged.
            let cleanVersion = trimmed.split(separator: " ").last.map(String.init) ?? trimmed
            AppLog.shared.log("codex --version OK: \(trimmed)", level: .info)
            return ProbeResult(version: cleanVersion, error: nil)
        } else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            AppLog.shared.log("codex --version exit=\(result.exitCode) stderr=\(err)", level: .warn)
            return ProbeResult(version: nil, error: err.isEmpty ? "exit \(result.exitCode)" : err)
        }
    }
}
