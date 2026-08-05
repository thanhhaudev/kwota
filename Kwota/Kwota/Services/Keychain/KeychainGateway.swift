//
//  KeychainGateway.swift
//  Kwota
//
//  The single place in the app that talks to Security.framework.
//
//  Two properties make this type worth existing:
//
//  1. Every call leaves the main thread. A Keychain consent dialog blocks the
//     thread that asked, for as long as it takes a human to answer — two hours,
//     on 2026-08-04. On the main actor that froze the whole app, and with it
//     keep-awake, so the Mac stopped being held awake while agents were working.
//
//  2. Calls are serialised. The flag that suppresses the consent dialog is
//     process-global, so two concurrent Keychain calls would trample each
//     other's setting and a background read could still raise a dialog.
//
//  Because the queue is serial, a probe parked inside SecItemCopyMatching would
//  otherwise block every later call forever. `wedged` breaks that: once a call
//  misses its deadline the gateway fails subsequent calls immediately rather
//  than enqueuing them behind the parked one, and clears itself when the parked
//  work finally answers.
//
//  `wedged` only ever gets armed by a `.deny` timeout (a background probe
//  nobody is watching) — a parked `.allow` call is the opposite, a human
//  actively looking at the dialog it raised, so it must not punish every
//  other caller. But the fast-fail applies to `.deny` only when wedged; a
//  wedged gateway must not ALSO permanently lock out `.allow` — that would
//  strand the Grant button, the very thing meant to recover from this state.
//  See `run(interaction:_:)` for the escape hatch that keeps `.allow`
//  reachable once wedged, and why it's safe.
//
//  That escape hatch runs `.allow` on a second queue while wedged, which
//  means for a while there can be TWO closures alive that are each allowed
//  to write the process-global interaction flag: the original parked probe
//  on `queue`, and the escape closure on `allowEscapeQueue`. `.deny` failing
//  fast whenever `wedged` is true keeps that safe — but `wedged` clearing
//  (the parked probe finally answering) and the escape closure finishing
//  (a human finally answering the Grant dialog) are two independent events;
//  the first can happen while the second hasn't. `escapeCallsInFlight`
//  covers that gap: `.deny` fails fast whenever it's non-zero too, even
//  after `wedged` itself has cleared, so a fresh `.deny` call can never
//  resume on the primary queue while an escape closure is still draining.
//

import Foundation
import Security

nonisolated enum KeychainInteraction: Sendable, Equatable {
    /// Background paths. A consent dialog is a defect here, not a prompt.
    case deny
    /// User-initiated paths only — the person is at the machine to answer.
    case allow
}

nonisolated enum KeychainGatewayError: Error, Equatable {
    case interactionNotAllowed
    case timedOut
    case status(OSStatus)
}

/// The raw Security.framework calls, injectable so tests never touch the real
/// Keychain and can simulate a probe that never answers.
nonisolated struct KeychainPrimitives: Sendable {
    var copyMatching: @Sendable ([String: Any]) -> (OSStatus, AnyObject?)
    var add: @Sendable ([String: Any]) -> OSStatus
    var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
    var delete: @Sendable ([String: Any]) -> OSStatus
    var setInteractionAllowed: @Sendable (Bool) -> Void

    static let live = KeychainPrimitives(
        copyMatching: { query in
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        delete: { SecItemDelete($0 as CFDictionary) },
        setInteractionAllowed: { SecKeychainSetUserInteractionAllowed($0) }
    )
}

nonisolated protocol KeychainGateways: Sendable {
    func read(service: String, account: String?, interaction: KeychainInteraction) async throws -> Data?
    func write(_ data: Data, service: String, account: String) async throws
    func delete(service: String, account: String) async throws
    func deleteAll(service: String) async throws
}

nonisolated final class KeychainGateway: KeychainGateways, @unchecked Sendable {
    static let shared = KeychainGateway()

    private let queue = DispatchQueue(label: "com.thanhhaudev.kwota.keychain")
    /// Escape hatch for `.allow` calls made while the gateway is already
    /// `wedged` — see `run(interaction:_:)` for when this is used and why
    /// it's safe. Not used for anything else: a non-wedged `.allow` call
    /// still goes through the primary `queue` like every other call, to
    /// keep the interaction-flag serialization guarantee intact whenever
    /// that guarantee is still meaningful.
    private let allowEscapeQueue = DispatchQueue(label: "com.thanhhaudev.kwota.keychain.allow-escape")
    private let primitives: KeychainPrimitives
    private let timeout: TimeInterval
    /// Deadline for `.allow` calls only. A real consent dialog routinely
    /// takes longer than the background `timeout` to answer — a human has to
    /// notice and click it — so `.allow` gets a much longer, separate budget
    /// rather than sharing the tight background deadline.
    private let allowTimeout: TimeInterval
    private let lock = NSLock()
    private var wedged = false
    /// Count of `.allow` escape-queue closures (see `run(interaction:_:)`)
    /// currently between "dispatched" and "finished running its own body,
    /// including its own post-work interaction-flag reset" — NOT the same
    /// window as the `async` call awaiting it, which can give up at its own
    /// deadline while the underlying `SecItemCopyMatching` call keeps
    /// running in the background (it isn't cancellable). `.deny` must fail
    /// fast whenever this is non-zero, exactly like it does while `wedged`
    /// — otherwise a `.deny` call freed by `wedged` clearing could resume on
    /// the primary `queue` while a still-draining escape closure is also
    /// live, and the two would race writes to the shared interaction flag.
    private var escapeCallsInFlight = 0

    init(primitives: KeychainPrimitives = .live, timeout: TimeInterval = 10, allowTimeout: TimeInterval = 120) {
        self.primitives = primitives
        self.timeout = timeout
        self.allowTimeout = allowTimeout
    }

    func read(service: String, account: String?, interaction: KeychainInteraction) async throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        let primitives = self.primitives
        return try await run(interaction: interaction) { () throws -> Data? in
            let (status, result) = primitives.copyMatching(query)
            switch status {
            case errSecSuccess: return result as? Data
            case errSecItemNotFound: return nil
            // errSecAuthFailed (-25293) is what the legacy suppression API
            // (`SecKeychainSetUserInteractionAllowed(false)`) actually returns
            // for a denied/untrusted read in production — NOT
            // errSecInteractionNotAllowed (-25308), which is the modern API's
            // shape. See docs/findings/F-005-keychain-interaction-suppression.md:
            // wire-measured on 2026-08-05 (`mode=legacy status=-25293`).
            // Without this case a real-world denial falls through to the
            // generic `.status` branch below and every denial-vs-absence
            // consumer (Grant banner, cache preservation) never activates.
            case errSecInteractionNotAllowed, errSecUserCanceled, errSecAuthFailed:
                throw KeychainGatewayError.interactionNotAllowed
            default: throw KeychainGatewayError.status(status)
            }
        }
    }

    func write(_ data: Data, service: String, account: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let primitives = self.primitives
        // Writes are only reached from user-initiated paths, but they are still
        // sent with `.deny`: a write that would need consent is a signal, not
        // something to silently prompt for behind a save button.
        try await run(interaction: .deny) {
            let status = primitives.update(query, [kSecValueData as String: data])
            switch status {
            case errSecSuccess: return
            case errSecItemNotFound:
                var insert = query
                insert[kSecValueData as String] = data
                let addStatus = primitives.add(insert)
                guard addStatus == errSecSuccess else {
                    throw KeychainGatewayError.status(addStatus)
                }
            // See the matching comment in `read()` — errSecAuthFailed is the
            // real-world denial status under legacy suppression (F-005).
            case errSecInteractionNotAllowed, errSecUserCanceled, errSecAuthFailed:
                throw KeychainGatewayError.interactionNotAllowed
            default: throw KeychainGatewayError.status(status)
            }
        }
    }

    func delete(service: String, account: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        try await deleteMatching(query)
    }

    /// `kSecMatchLimitAll` is required: without it `SecItemDelete` removes one
    /// matching item on macOS and silently leaves the rest.
    func deleteAll(service: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        try await deleteMatching(query)
    }

    private func deleteMatching(_ query: [String: Any]) async throws {
        let primitives = self.primitives
        try await run(interaction: .deny) {
            let status = primitives.delete(query)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainGatewayError.status(status)
            }
        }
    }

    /// Hands `work` to the serial queue, applies the interaction policy around
    /// it, and returns to the caller at the deadline whether or not the work
    /// answered. The parked thread is not cancellable — `SecItemCopyMatching`
    /// answers no cancellation — so the deadline protects the caller, and
    /// `wedged` protects everyone behind it.
    ///
    /// The escape hatch: when `wedged` is already true (a `.deny` probe is
    /// permanently parked inside `SecItemCopyMatching` on `queue`), a `.deny`
    /// call still fails fast, unchanged. But an `.allow` call is routed to
    /// `allowEscapeQueue` instead of `queue` — enqueuing it behind the
    /// permanently-parked closure would mean it could never run at all,
    /// which would strand the Grant button exactly when the user is trying
    /// to use it to recover from this state.
    ///
    /// Why this doesn't reopen the interaction-flag race the single serial
    /// queue exists to prevent: the parked closure is blocked *inside*
    /// `SecItemCopyMatching`, past the point where it already read the
    /// process-global interaction flag for its own call — a second queue
    /// changing that flag afterward cannot affect a call already in flight,
    /// only calls that haven't started yet. And a `.deny` call never starts
    /// while `wedged` OR `escapeCallsInFlight` is non-zero — it fails fast
    /// below, before ever touching the flag — so there is never a live
    /// `.deny` call for a concurrent `.allow` call to corrupt. `allowEscapeQueue`
    /// is itself serial, so multiple `.allow` calls racing this path still
    /// serialize against each other.
    ///
    /// The two guards cover two different windows, and BOTH are required:
    /// `wedged` covers "the original probe is still stuck," and
    /// `escapeCallsInFlight` covers "an escape closure is still draining" —
    /// these clear at different, independent times (the stuck probe
    /// finally answering has nothing to do with when the human answers the
    /// Grant dialog), so gating on `wedged` alone would let a `.deny` call
    /// resume on the primary queue the instant the probe returns, even
    /// while an escape closure was still live and free to write the same
    /// flag a moment later. `escapeCallsInFlight` tracks the escape
    /// closure's own body — dispatched through its final
    /// `setInteractionAllowed(true)` reset — not the `async` call awaiting
    /// it, which can give up at its own deadline while the closure keeps
    /// running in the background.
    ///
    /// `allowEscapeQueue` work deliberately does NOT clear `wedged` on
    /// completion: its success or failure says nothing about whether the
    /// original parked closure on `queue` has unstuck. Only that closure's
    /// own completion (on `queue`) is evidence the primary queue is usable
    /// again.
    private func run<T: Sendable>(
        interaction: KeychainInteraction,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        lock.lock()
        let isWedged = wedged
        let hasDrainingEscapeCalls = escapeCallsInFlight > 0
        lock.unlock()

        if interaction == .deny, isWedged || hasDrainingEscapeCalls {
            throw KeychainGatewayError.timedOut
        }

        if isWedged {
            // `.deny` already threw above — only `.allow` reaches here.
            return try await enqueue(on: allowEscapeQueue, interaction: interaction, clearsWedgeOnCompletion: false, tracksEscapeInFlight: true, work)
        }

        return try await enqueue(on: queue, interaction: interaction, clearsWedgeOnCompletion: true, tracksEscapeInFlight: false, work)
    }

    private func enqueue<T: Sendable>(
        on targetQueue: DispatchQueue,
        interaction: KeychainInteraction,
        clearsWedgeOnCompletion: Bool,
        tracksEscapeInFlight: Bool,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        if tracksEscapeInFlight {
            lock.lock()
            escapeCallsInFlight += 1
            lock.unlock()
        }
        let primitives = self.primitives
        let deadline = interaction == .allow ? allowTimeout : timeout
        return try await withCheckedThrowingContinuation { continuation in
            let settled = Settled()
            targetQueue.async { [weak self] in
                primitives.setInteractionAllowed(interaction == .allow)
                let outcome = Result { try work() }
                primitives.setInteractionAllowed(true)
                if clearsWedgeOnCompletion {
                    self?.lock.lock()
                    self?.wedged = false
                    self?.lock.unlock()
                }
                // Decremented unconditionally here — on the closure's own
                // completion, not on whether the `async` caller already
                // gave up at its deadline (`settled.claim()` below). Those
                // are different events: this decrement is what closes the
                // wedge-clear boundary race, so it must track when the
                // underlying `SecItemCopyMatching` call actually returns.
                if tracksEscapeInFlight {
                    self?.lock.lock()
                    self?.escapeCallsInFlight -= 1
                    self?.lock.unlock()
                }
                if settled.claim() { continuation.resume(with: outcome) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) { [weak self] in
                guard settled.claim() else { return }
                // `wedged` exists to protect background callers from a
                // background probe nobody is watching. A parked `.allow`
                // call is the opposite: a human is actively looking at the
                // dialog it raised. Punishing every other background caller
                // (token refreshes, deletes, reads) while that dialog is
                // still open is the defect this guard exists to avoid —
                // so only a `.deny` call arms `wedged`.
                if interaction == .deny {
                    self?.lock.lock()
                    self?.wedged = true
                    self?.lock.unlock()
                }
                continuation.resume(throwing: KeychainGatewayError.timedOut)
            }
        }
    }
}

/// One-shot winner election between the work and its deadline. A
/// `CheckedContinuation` must be resumed exactly once.
private final class Settled: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
