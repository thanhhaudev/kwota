//
//  AgyProbe.swift
//  Kwota
//

import Foundation

/// `agy --version` probe (Antigravity's CLI). The binary prints a bare
/// semver like `1.0.2`; we trim and return it verbatim. Same launcher /
/// PATH-augmentation strategy as ClaudeProbe / CodexProbe.
final class AgyProbe {
    private let launcher: ProcessLauncher

    init(launcher: ProcessLauncher = SystemProcessLauncher()) {
        self.launcher = launcher
    }

    func run() async throws -> ProbeResult {
        let path = ClaudeProbe.augmentedPATH(existing: ProcessInfo.processInfo.environment["PATH"] ?? "")
        let result = try launcher.run(
            executable: "/usr/bin/env",
            arguments: ["-S", "PATH=\(path)", "agy", "--version"],
            environment: nil
        )

        if result.exitCode == 0 {
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // If a future agy build adds a prefix (`agy 1.0.2`), keep the
            // trailing token; bare output passes through unchanged.
            let cleanVersion = trimmed.split(separator: " ").last.map(String.init) ?? trimmed
            AppLog.shared.log("agy --version OK: \(trimmed)", level: .info)
            return ProbeResult(version: cleanVersion, error: nil)
        } else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            AppLog.shared.log("agy --version exit=\(result.exitCode) stderr=\(err)", level: .warn)
            return ProbeResult(version: nil, error: err.isEmpty ? "exit \(result.exitCode)" : err)
        }
    }
}
