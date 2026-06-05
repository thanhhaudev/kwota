//
//  DebugReportExporter.swift
//  Kwota
//

import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class DebugReportExporter {
    static let shared = DebugReportExporter()

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private let eventTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func present(vm: MenuBarViewModel) async {
        let snapshot = await SystemInfoProvider.snapshot(registry: vm.registry)
        let payload = buildPayload(
            events: vm.recentEvents,
            rawLine: vm.usage.reader.lastSeenLine(),
            logLines: AppLog.shared.snapshot(),
            snapshot: snapshot,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )

        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFilename()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        do {
            try payload.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            AppLog.shared.log(
                "DebugReportExporter: write failed at \(url.path): \(error)",
                level: .warn
            )
        }
    }

    func defaultFilename(now: Date = Date()) -> String {
        "kwota-debug-\(filenameFormatter.string(from: now)).txt"
    }

    func buildPayload(
        events: [UsageEvent],
        rawLine: String?,
        logLines: [String],
        snapshot: SystemSnapshot?,
        appVersion: String?,
        now: Date = Date()
    ) -> String {
        var out = ""
        out += "Kwota Debug Report\n"
        out += "Generated: \(isoFormatter.string(from: now))\n"
        out += "================================\n\n"

        out += "System\n"
        out += "------\n"
        var systemLines: [String] = []
        if let appVersion {
            systemLines.append("Kwota: \(appVersion)")
        }
        if let snap = snapshot {
            systemLines.append("macOS: \(snap.macOSVersion)")
            for cli in snap.providerCLIs {
                systemLines.append("\(cli.displayName) CLI: \(cli.version ?? "Not installed")")
            }
        }
        if systemLines.isEmpty {
            out += "(none)\n"
        } else {
            for line in systemLines { out += "\(line)\n" }
        }
        out += "\n"

        out += "Recent Events (\(events.count))\n"
        out += "------------------\n"
        if events.isEmpty {
            out += "(none)\n"
        } else {
            for ev in events {
                let time = eventTimeFormatter.string(from: ev.timestamp)
                let sid = String(ev.sessionId.prefix(8))
                out += "\(time)  s=\(sid)  in=\(ev.tokens.input)  out=\(ev.tokens.output)\n"
            }
        }
        out += "\n"

        out += "Raw Last JSONL Line\n"
        out += "-------------------\n"
        let trimmedRaw = (rawLine ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        out += trimmedRaw.isEmpty ? "(none)\n" : "\(trimmedRaw)\n"
        out += "\n"

        let tail = logLines.suffix(200)
        out += "Log (last \(tail.count) lines)\n"
        out += "--------------------\n"
        if tail.isEmpty {
            out += "(none)\n"
        } else {
            for line in tail { out += "\(line)\n" }
        }

        return out
    }
}
