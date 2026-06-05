//
//  main.swift
//  KwotaPrivilegedHelper
//
//  Root LaunchDaemon registered via SMAppService. Hosts a single XPC
//  service. It does the absolute minimum as root: clear the contents of
//  caches named by identifiers from SystemCacheCatalog, and restart Finder
//  when an icon cache was cleared. It never accepts a path — see
//  SystemCacheCatalog for the security rationale.
//

import Foundation

final class HelperDelegate: NSObject, NSXPCListenerDelegate, KwotaPrivilegedHelperProtocol {

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Refuse any caller we can't verify came from the real, same-team app.
        guard let team = KwotaHelperInfo.currentTeamIdentifier() else { return false }
        connection.setCodeSigningRequirement(KwotaHelperInfo.appCodeRequirement(team: team))
        connection.exportedInterface = KwotaHelperInfo.makeXPCInterface()
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func helperVersion(reply: @escaping (String) -> Void) {
        reply(KwotaHelperInfo.version)
    }

    func cleanSystemCaches(identifiers: [String],
                           reply: @escaping (Int, Int64, String?) -> Void) {
        let cleaner = SystemCacheCleaner()
        var totalItems = 0
        var totalBytes: Int64 = 0
        var firstError: String?
        var shouldRestartFinder = false

        for identifier in identifiers {
            // Unknown identifier → silently skipped. The catalog is the
            // only path source; a caller cannot widen this set.
            guard let entry = SystemCacheCatalog.entry(for: identifier) else { continue }
            let outcome = cleaner.clearContents(of: URL(fileURLWithPath: entry.path))
            totalItems += outcome.itemsRemoved
            totalBytes += outcome.bytesFreed
            if firstError == nil { firstError = outcome.firstError }
            if entry.restartsFinder && outcome.itemsRemoved > 0 {
                shouldRestartFinder = true
            }
        }

        if shouldRestartFinder {
            Self.restartFinder()
        }
        reply(totalItems, totalBytes, firstError)
    }

    func systemCacheSizes(identifiers: [String],
                          reply: @escaping ([String: Int64]) -> Void) {
        let cleaner = SystemCacheCleaner()
        var sizes: [String: Int64] = [:]
        for identifier in identifiers {
            guard let entry = SystemCacheCatalog.entry(for: identifier) else { continue }
            sizes[identifier] = cleaner.totalSize(of: URL(fileURLWithPath: entry.path))
        }
        reply(sizes)
    }

    /// Restart Finder so it rebuilds icons after the icon cache is cleared.
    /// This replaces the old manual `sudo killall Finder` step.
    private static func restartFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
        process.waitUntilExit()
    }
}

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: KwotaHelperInfo.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
