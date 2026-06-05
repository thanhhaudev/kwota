//
//  ClaudeProbe.swift
//  Kwota
//

import Foundation

final class ClaudeProbe {
    private let launcher: ProcessLauncher

    init(launcher: ProcessLauncher = SystemProcessLauncher()) {
        self.launcher = launcher
    }

    func run() async throws -> ProbeResult {
        let path = Self.augmentedPATH(existing: ProcessInfo.processInfo.environment["PATH"] ?? "")
        let result = try launcher.run(
            executable: "/usr/bin/env",
            arguments: ["-S", "PATH=\(path)", "claude", "--version"],
            environment: nil
        )

        if result.exitCode == 0 {
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanVersion = trimmed.split(separator: " ", maxSplits: 1)
                                      .first
                                      .map(String.init) ?? trimmed
            AppLog.shared.log("claude --version OK: \(trimmed)", level: .info)
            return ProbeResult(version: cleanVersion, error: nil)
        } else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            AppLog.shared.log("claude --version exit=\(result.exitCode) stderr=\(err)", level: .warn)
            return ProbeResult(version: nil, error: err.isEmpty ? "exit \(result.exitCode)" : err)
        }
    }

    static func augmentedPATH(existing: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin"
        ]
        var seen = Set<String>()
        var ordered: [String] = []
        func add(_ s: String) {
            for part in s.split(separator: ":") where !part.isEmpty {
                let p = String(part)
                if seen.insert(p).inserted { ordered.append(p) }
            }
        }
        for e in extras { add(e) }
        add(existing)
        return ordered.joined(separator: ":")
    }
}
