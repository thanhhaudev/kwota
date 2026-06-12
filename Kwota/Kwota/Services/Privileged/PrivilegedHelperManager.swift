//
//  PrivilegedHelperManager.swift
//  Kwota
//
//  App-side wrapper over SMAppService + the helper XPC connection.
//  SMAppService and XPC sit behind `SystemServiceRegistering` /
//  `HelperConnecting` protocols so the status state machine is unit-tested
//  with fakes; the `Live*` conformances do the real work. Construct the
//  production instance with `PrivilegedHelperManager.live()`.
//

import Foundation
import ServiceManagement

/// What the rest of the app sees. `.requiresApproval` means the daemon is
/// registered but the user must still enable it in System Settings.
enum PrivilegedHelperStatus: Equatable {
    case notInstalled
    case requiresApproval
    case enabled
    case needsUpdate
}

/// Result of a successful system-cache clean.
struct SystemCleanOutcome: Equatable {
    let itemsRemoved: Int
    let bytesFreed: Int64
}

/// Failure modes surfaced to the Cache UI.
enum PrivilegedHelperError: Error, Equatable {
    /// Helper not installed / not enabled.
    case helperUnavailable
    /// XPC connection itself failed (helper crashed, not reachable).
    case connectionFailed(String)
    /// The helper ran but reported a delete error.
    case cleanFailed(String)
}

/// Abstraction over `SMAppService` so the manager is testable.
@MainActor
protocol SystemServiceRegistering {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

/// Abstraction over the helper XPC connection so the manager is testable.
@MainActor
protocol HelperConnecting {
    func helperVersion() async -> String?
    func cleanSystemCaches(
        identifiers: [String]
    ) async -> Result<SystemCleanOutcome, PrivilegedHelperError>
    func systemCacheSizes(identifiers: [String]) async -> [String: Int64]
}

@MainActor
@Observable
final class PrivilegedHelperManager {

    private(set) var status: PrivilegedHelperStatus = .notInstalled

    /// Whether the helper can work at all for this binary. An ad-hoc build
    /// has no team identifier, so the helper's fail-closed signing gate can
    /// never accept the connection — the entire system-cache feature is dead
    /// on arrival. The signature can't change while the process runs, so this
    /// is resolved once at init. UI surfaces hide helper affordances and
    /// catalog system caches when false.
    let isSupported: Bool

    private let service: SystemServiceRegistering
    private let connector: HelperConnecting

    init(
        service: SystemServiceRegistering,
        connector: HelperConnecting,
        isSupported: Bool = KwotaHelperInfo.currentTeamIdentifier() != nil
    ) {
        self.service = service
        self.connector = connector
        self.isSupported = isSupported
    }

    /// The production manager, wired to the real SMAppService + helper XPC.
    static func live() -> PrivilegedHelperManager {
        PrivilegedHelperManager(service: LiveSystemService(), connector: LiveHelperConnector())
    }

    /// Pure mapping from the raw service state (+ optionally the running
    /// helper's reported version) to the app-facing status. A nil
    /// `helperVersion` means "not queried yet" — treated as up to date so
    /// the status doesn't flap before the first XPC round-trip.
    static func resolveStatus(
        service: SMAppService.Status,
        helperVersion: String?
    ) -> PrivilegedHelperStatus {
        switch service {
        case .enabled:
            if let v = helperVersion, v != KwotaHelperInfo.version {
                return .needsUpdate
            }
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .notInstalled
        @unknown default:
            return .notInstalled
        }
    }

    /// Re-read the service state and (when enabled) the running helper's
    /// version, then publish the resolved status.
    func refreshStatus() async {
        let raw = service.status
        let version: String? = (raw == .enabled) ? await connector.helperVersion() : nil
        status = Self.resolveStatus(service: raw, helperVersion: version)
        AppLog.shared.log("PrivilegedHelperManager status → \(status)", level: .info)
    }

    /// Register the daemon. macOS shows its one-time approval; if it lands
    /// in `.requiresApproval` the caller routes the user to System Settings.
    func install() async {
        do {
            try service.register()
        } catch {
            AppLog.shared.log("PrivilegedHelperManager install failed: \(error)", level: .error)
        }
        await refreshStatus()
    }

    /// Reload an out-of-date daemon. A long-running root daemon does NOT pick
    /// up a new on-disk binary from a bare `register()`, so the stale helper
    /// must be unregistered (which terminates the running process) and then
    /// re-registered to relaunch the current executable. Backs the
    /// "Update helper" action. `unregister` is best-effort so a stale or
    /// already-removed job doesn't block the re-register.
    func update() async {
        try? service.unregister()
        do {
            try service.register()
        } catch {
            AppLog.shared.log("PrivilegedHelperManager update failed: \(error)", level: .error)
        }
        await refreshStatus()
    }

    /// Unregister the daemon.
    func uninstall() async {
        do {
            try service.unregister()
        } catch {
            AppLog.shared.log("PrivilegedHelperManager uninstall failed: \(error)", level: .error)
        }
        await refreshStatus()
    }

    /// Clean the named system caches. Fails fast with `.helperUnavailable`
    /// when the helper is not enabled — the connector is never reached.
    func cleanSystemCaches(
        identifiers: [String]
    ) async -> Result<SystemCleanOutcome, PrivilegedHelperError> {
        guard status == .enabled else { return .failure(.helperUnavailable) }
        return await connector.cleanSystemCaches(identifiers: identifiers)
    }

    /// Sizes for the named system caches, measured by the root helper. Returns
    /// empty when the helper isn't enabled — the connector is never reached.
    func systemCacheSizes(identifiers: [String]) async -> [String: Int64] {
        guard status == .enabled else { return [:] }
        return await connector.systemCacheSizes(identifiers: identifiers)
    }
}

// MARK: - Live conformances

/// Real `SMAppService` daemon registration.
@MainActor
final class LiveSystemService: SystemServiceRegistering {
    private let appService = SMAppService.daemon(plistName: KwotaHelperInfo.daemonPlistName)

    var status: SMAppService.Status { appService.status }

    func register() throws { try appService.register() }
    func unregister() throws { try appService.unregister() }
}

/// Real XPC connection to the privileged helper. A fresh connection is
/// made per call: these operations are rare (manual or background
/// auto-clean) and a short-lived connection avoids holding a Mach port
/// open for the app's whole lifetime.
@MainActor
final class LiveHelperConnector: HelperConnecting {

    /// Upper bound on a single helper XPC round-trip. A helper that accepts
    /// the connection but never replies (deadlock, infinite loop) would
    /// otherwise leave the caller awaiting forever and wedge cache-clean
    /// in-flight state; the timeout resumes the continuation with a failure
    /// instead so callers can clear their flags and surface a retry.
    /// The fast probes (`helperVersion`/`systemCacheSizes`) use this as their
    /// authoritative deadline and deliberately omit the interruption/
    /// invalidation handlers that `cleanSystemCaches` installs — a probe that
    /// can't reach the helper simply times out harmlessly.
    private static let callTimeout: TimeInterval = 30

    /// Generous upper bound for a system-cache clean. Unlike `callTimeout`
    /// this is NOT a correctness mechanism: a large delete (the icon cache
    /// can be tens of GB of tiny files) legitimately runs for minutes, so the
    /// helper's real reply is the source of truth. A crashed or killed helper
    /// is reported immediately by the connection handlers; this backstop only
    /// clears in-flight state if the helper is alive but wedged with no crash.
    /// A genuinely slow-but-healthy delete that runs past this ceiling would
    /// surface as a false failure (the inverse of the 30s bug, at a far higher
    /// threshold) — raise it if real deletes ever approach 10 minutes.
    ///
    /// Accepted limitation: invalidating the client connection does NOT cancel
    /// the root delete (the helper has no cancellation/op-status API — that's
    /// the deferred heartbeat protocol). So past the backstop the caller clears
    /// its in-flight state and a retry could overlap a still-running root
    /// delete. Tolerated because (a) it only bites when a delete is wedged
    /// >10 min, far rarer than the prior 30s timeout it replaced, and
    /// (b) repeated cache-file deletes are idempotent-safe.
    private static let cleanBackstop: TimeInterval = 600

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: KwotaHelperInfo.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = KwotaHelperInfo.makeXPCInterface()
        // Only our real, same-team helper may answer. If we can't resolve our
        // own team (unsigned/ad-hoc build), skip the requirement and log — the
        // connection will simply fail to do useful work rather than crash.
        if let team = KwotaHelperInfo.currentTeamIdentifier() {
            connection.setCodeSigningRequirement(KwotaHelperInfo.helperCodeRequirement(team: team))
        } else {
            AppLog.shared.log(
                "PrivilegedHelper: could not resolve own team identifier; XPC code requirement not set",
                level: .error)
        }
        // The caller resumes after installing any connection handlers, so a
        // crash or interruption during setup can never land before its
        // handler is in place.
        return connection
    }

    func helperVersion() async -> String? {
        await withCheckedContinuation { continuation in
            let connection = makeConnection()
            connection.resume()
            var resumed = false
            // Every resume path funnels through the main queue, so the
            // one-shot `resumed` guard is checked and set without a race
            // between the XPC reply, the error handler, and the timeout.
            let finish: (String?) -> Void = { value in
                DispatchQueue.main.async {
                    guard !resumed else { return }
                    resumed = true
                    connection.invalidate()
                    continuation.resume(returning: value)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.callTimeout) {
                finish(nil)
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                finish(nil)
            } as? KwotaPrivilegedHelperProtocol
            guard let proxy else { finish(nil); return }
            proxy.helperVersion { version in finish(version) }
        }
    }

    func cleanSystemCaches(
        identifiers: [String]
    ) async -> Result<SystemCleanOutcome, PrivilegedHelperError> {
        await withCheckedContinuation { continuation in
            let connection = makeConnection()
            var resumed = false
            let finish: (Result<SystemCleanOutcome, PrivilegedHelperError>) -> Void = { result in
                DispatchQueue.main.async {
                    guard !resumed else { return }
                    resumed = true
                    connection.invalidate()
                    continuation.resume(returning: result)
                }
            }
            // A crashed/killed/interrupted helper is reported immediately
            // rather than waiting out the backstop. Our own `finish` call
            // invalidates the connection, which re-enters invalidationHandler,
            // but the one-shot `resumed` guard makes that a no-op.
            connection.interruptionHandler = {
                finish(.failure(.connectionFailed("the privileged helper connection was interrupted")))
            }
            connection.invalidationHandler = {
                finish(.failure(.connectionFailed("the privileged helper connection was invalidated")))
            }
            // Resume only after both handlers are installed, so a crash or
            // interruption during connection setup is reported via finish()
            // rather than slipping through to the backstop.
            connection.resume()
            // Backstop only — a slow-but-healthy delete does NOT trip this; it
            // returns via the helper's real reply below well before 10 min.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.cleanBackstop) {
                finish(.failure(.connectionFailed("the privileged helper did not respond in time")))
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                finish(.failure(.connectionFailed(error.localizedDescription)))
            } as? KwotaPrivilegedHelperProtocol
            guard let proxy else {
                finish(.failure(.connectionFailed("could not obtain helper proxy")))
                return
            }
            proxy.cleanSystemCaches(identifiers: identifiers) { items, bytes, errorMessage in
                if let errorMessage {
                    finish(.failure(.cleanFailed(errorMessage)))
                } else {
                    finish(.success(SystemCleanOutcome(itemsRemoved: items, bytesFreed: bytes)))
                }
            }
        }
    }

    func systemCacheSizes(identifiers: [String]) async -> [String: Int64] {
        await withCheckedContinuation { continuation in
            let connection = makeConnection()
            connection.resume()
            var resumed = false
            let finish: ([String: Int64]) -> Void = { value in
                DispatchQueue.main.async {
                    guard !resumed else { return }
                    resumed = true
                    connection.invalidate()
                    continuation.resume(returning: value)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.callTimeout) { finish([:]) }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                AppLog.shared.log(
                    "systemCacheSizes XPC error: \(error.localizedDescription)",
                    level: .error)
                finish([:])
            } as? KwotaPrivilegedHelperProtocol
            guard let proxy else { finish([:]); return }
            proxy.systemCacheSizes(identifiers: identifiers) { finish($0) }
        }
    }
}
