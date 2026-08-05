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
//  `wedged` is a LAGGING signal, though: it only becomes true once a parked
//  call misses its own full `timeout` (10s by default). If a probe gets
//  stuck at time T, there's a window up to T+timeout where the gateway
//  doesn't know it yet. An `.allow` call arriving in that window used to see
//  `wedged == false` and queue normally behind the stuck probe on `queue` —
//  same practical effect as the original bug, just bounded by `allowTimeout`
//  instead of unbounded. `primaryOccupantSince` / `primaryQueueProbablyStuck()`
//  close that gap with a second, much shorter grace period
//  (`allowGraceInterval`) that applies to `.allow` only: if the primary
//  queue's current occupant has been running longer than that short grace
//  period — whether or not it's hit its own full deadline — a newly
//  arriving `.allow` call routes to `allowEscapeQueue` just like the
//  wedged-true case. See `primaryQueueProbablyStuck()` for why this is safe
//  at a much shorter threshold than `timeout` itself.
//
//  A third adversarial-review round (round 6 of this file's history) found
//  two more gaps, both fixed below:
//
//  First: every call's deadline timer is armed the instant `enqueue(...)`
//  is called, independent of whether that call has actually started
//  running yet — it may still be sitting in `queue`'s FIFO backlog behind
//  a slow-but-not-wedged occupant. If the deadline fires while a call is
//  still queued, the caller already receives `.timedOut` — but the old
//  code still ran `work()` unconditionally once the call's turn finally
//  came, silently mutating the real Keychain long after the caller gave
//  up (for a write, potentially clobbering a NEWER write from a
//  subsequent successful retry with STALE data). `Settled.peek()` — a
//  non-consuming check, unlike the one-shot `claim()` — lets the
//  work-side ask "did my own deadline already win" without itself racing
//  to become the side that delivers the result; if it did, `work()` is
//  skipped, but the four pieces of unconditional bookkeeping
//  (`clearsWedgeOnCompletion`, `marksPrimaryOccupancy`'s clear + waiter
//  release, `tracksEscapeInFlight`'s decrement) still run exactly as
//  before — skipping those would reopen the stranding bugs rounds 4 and 5
//  closed. This peek is checked AFTER the existing top-of-closure `.deny`
//  re-check (see `enqueue(...)`): that re-check's own bail path already
//  skips `work()` entirely when it fires, so ordering only matters for the
//  calls that survive it — `.deny` calls that aren't wedged/draining, and
//  every `.allow` call (which the `.deny`-only re-check never applies to).
//
//  Second: `run(interaction:_:)`'s routing decision for `.allow` has its
//  own check-then-enqueue race. It snapshots `wedged`/`escapeCallsInFlight`
//  synchronously, then `await`s `primaryQueueProbablyStuck()` — a genuine
//  suspension point. A completely different `.deny` call can be admitted
//  onto the primary queue during that suspension and become its new
//  occupant — one `primaryQueueProbablyStuck()` never evaluated, because it
//  didn't exist yet when the check ran. Without a fix, the `.allow` call
//  proceeds to enqueue on the primary queue trusting a stale "looked safe"
//  answer, and can land behind this fresh, undetected occupant with no
//  escape route. `primaryAdmissionGeneration` (bumped under `lock` every
//  time ANY call is admitted onto the primary `queue`, in `run(...)`
//  itself, right where the admission decision is made) closes this: after
//  `primaryQueueProbablyStuck()` returns `false`, `run(...)` atomically
//  checks-and-claims admission via `tryClaimPrimaryQueueAdmission(unlessRacedSince:)`.
//  If the generation moved, something new was admitted during the
//  suspension — rather than blindly rerouting to the escape queue (which
//  would risk the exact interaction-flag trample this file's serial design
//  exists to prevent, if the fresh occupant hasn't yet reached the point in
//  its own closure where it captures the flag), `run(...)` re-evaluates by
//  calling `primaryQueueProbablyStuck()` a second time — the same
//  already-established-safe check, now aimed at whatever is actually
//  there, after a brief fixed settle delay (paid only on this already-rare
//  race path) that gives the freshly-admitted call a realistic chance to
//  have actually started running before its occupancy is read. Only if
//  that second look also says "stuck" does the call escape; if it
//  says "healthy," admission is claimed unconditionally. A narrower window
//  remains after that second claim — the purely synchronous gap between
//  claiming the generation and `enqueue(...)`'s actual `targetQueue.async`
//  call — but that is Swift/GCD call overhead, not another `await`
//  suspension, mirroring how round 3's own grace-period fix left (and
//  documented) a narrower residual that a later round then closed further.
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
    /// `wedged`, OR while the primary queue's current occupant merely looks
    /// probably-stuck (`primaryQueueProbablyStuck()`) — see
    /// `run(interaction:_:)` for when each is used and why both are safe.
    /// Not used for anything else: an `.allow` call whose primary queue is
    /// idle, or occupied by something that's about to clear, still goes
    /// through the primary `queue` like every other call, to keep the
    /// interaction-flag serialization guarantee intact whenever that
    /// guarantee is still meaningful.
    private let allowEscapeQueue = DispatchQueue(label: "com.thanhhaudev.kwota.keychain.allow-escape")
    private let primitives: KeychainPrimitives
    private let timeout: TimeInterval
    /// Deadline for `.allow` calls only. A real consent dialog routinely
    /// takes longer than the background `timeout` to answer — a human has to
    /// notice and click it — so `.allow` gets a much longer, separate budget
    /// rather than sharing the tight background deadline.
    private let allowTimeout: TimeInterval
    /// Grace period for `.allow` only, deliberately much shorter than
    /// `timeout` — see `primaryQueueProbablyStuck()`. Not a deadline for any
    /// call; purely a "how long is too long to still call this normal"
    /// threshold used to decide routing.
    private let allowGraceInterval: TimeInterval
    private let lock = NSLock()
    private var wedged = false
    /// When the primary `queue`'s current occupant closure started running,
    /// or `nil` when the queue is idle. Set at the top of that closure's
    /// body and cleared at the bottom — see `enqueue(...)`'s
    /// `marksPrimaryOccupancy` parameter. Read by `primaryQueueProbablyStuck()`
    /// to answer "has whatever is on the primary queue right now been
    /// running longer than a human-imperceptible grace period" without
    /// waiting for that occupant's own full deadline.
    private var primaryOccupantSince: Date?
    /// Closures to run once the primary queue's current occupant finishes —
    /// each one resolves a still-pending `primaryQueueProbablyStuck()` call
    /// with "no, it cleared in time." Drained and cleared every time the
    /// occupant finishes (see `enqueue(...)`).
    private var primaryQueueWaiters: [() -> Void] = []
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
    /// Bumped under `lock` every time `run(interaction:_:)` admits ANY call
    /// (`.deny` or `.allow`) onto the primary `queue` — distinct from
    /// `primaryOccupantSince`, which tracks when the current occupant
    /// started RUNNING (a closure can be admitted, i.e. dispatched via
    /// `targetQueue.async`, well before it actually gets its turn if
    /// something is already ahead of it). `run(...)` reads this
    /// immediately before `await primaryQueueProbablyStuck()` suspends, and
    /// again right after — via `tryClaimPrimaryQueueAdmission(unlessRacedSince:)`
    /// — to detect whether a DIFFERENT call was admitted onto the primary
    /// queue during that suspension. See the file header and `run(...)`.
    private var primaryAdmissionGeneration = 0

    init(
        primitives: KeychainPrimitives = .live,
        timeout: TimeInterval = 10,
        allowTimeout: TimeInterval = 120,
        allowGraceInterval: TimeInterval = 0.5
    ) {
        self.primitives = primitives
        self.timeout = timeout
        self.allowTimeout = allowTimeout
        self.allowGraceInterval = allowGraceInterval
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
    ///
    /// Between "not wedged yet" and "confirmed wedged" there is a third
    /// case, checked only for `.allow`: the primary queue is occupied by
    /// something that hasn't answered within `allowGraceInterval` (far
    /// shorter than `timeout`), but hasn't missed its own full deadline
    /// either — see `primaryQueueProbablyStuck()`.
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
            return try await enqueue(on: allowEscapeQueue, interaction: interaction, clearsWedgeOnCompletion: false, tracksEscapeInFlight: true, marksPrimaryOccupancy: false, work)
        }

        if interaction == .allow {
            // Captured BEFORE the suspension below — this is what
            // `tryClaimPrimaryQueueAdmission(unlessRacedSince:)` compares
            // against afterward to detect a fresh admission that raced in
            // during the `await`. See the file header ("Second: ...").
            let admissionGenerationAtEntry = primaryAdmissionGenerationSnapshot()

            if await primaryQueueProbablyStuck() {
                // Detection-lag gap: the primary queue's current occupant
                // has been running longer than the short grace period, but
                // hasn't hit ITS OWN full `timeout` yet, so `wedged` hasn't
                // flipped. Routing here is safe for the same reason
                // routing while `wedged` is true is safe (see
                // `primaryQueueProbablyStuck()`).
                return try await enqueue(on: allowEscapeQueue, interaction: interaction, clearsWedgeOnCompletion: false, tracksEscapeInFlight: true, marksPrimaryOccupancy: false, work)
            }

            if !tryClaimPrimaryQueueAdmission(unlessRacedSince: admissionGenerationAtEntry) {
                // Admission-race gap (Finding 2, round 6): a DIFFERENT call
                // was admitted onto the primary queue during the
                // `await primaryQueueProbablyStuck()` suspension above —
                // the "looked safe" answer we just got evaluated a queue
                // state that no longer holds. Re-evaluate for real against
                // whatever is actually there now, rather than either
                // trusting the stale answer OR blindly rerouting to the
                // escape queue (which could reopen the interaction-flag
                // trample risk if the fresh occupant hasn't yet reached the
                // point in its own closure where it captures the flag —
                // see `primaryQueueProbablyStuck()`'s own safety argument).
                //
                // The freshly-admitted call may have only just been
                // dispatched (via `targetQueue.async`) and not yet actually
                // STARTED running — `primaryOccupantSince` is set at the
                // top of ITS closure, not at admission time (see
                // `primaryAdmissionGeneration`'s doc comment). A brief,
                // fixed settle delay here — bounded, and only ever paid on
                // this already-rare race path, never the common fast path
                // — gives GCD a realistic chance to actually start it
                // before this second look reads its occupancy, so "second
                // look says healthy" reflects the new call's real state
                // rather than pure dispatch latency.
                try? await Task.sleep(nanoseconds: 20_000_000)
                if await primaryQueueProbablyStuck() {
                    return try await enqueue(on: allowEscapeQueue, interaction: interaction, clearsWedgeOnCompletion: false, tracksEscapeInFlight: true, marksPrimaryOccupancy: false, work)
                }
                // Second look agrees it's healthy. Claim unconditionally —
                // a further race in the now-purely-synchronous gap before
                // `enqueue(...)`'s actual `targetQueue.async` call is the
                // narrower residual window documented in the file header;
                // closing it fully would require a fundamentally different
                // admission mechanism, out of scope for this fix.
                claimPrimaryQueueAdmissionUnconditionally()
            }
            return try await enqueue(on: queue, interaction: interaction, clearsWedgeOnCompletion: true, tracksEscapeInFlight: false, marksPrimaryOccupancy: true, work)
        }

        claimPrimaryQueueAdmissionUnconditionally()
        return try await enqueue(on: queue, interaction: interaction, clearsWedgeOnCompletion: true, tracksEscapeInFlight: false, marksPrimaryOccupancy: true, work)
    }

    /// Snapshot of `primaryAdmissionGeneration`, taken under `lock`. See
    /// `run(interaction:_:)` and `tryClaimPrimaryQueueAdmission(unlessRacedSince:)`.
    private func primaryAdmissionGenerationSnapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return primaryAdmissionGeneration
    }

    /// Atomically checks whether any call has been admitted to the primary
    /// queue since `expectedGeneration` was captured and, if not, claims
    /// THIS call's own admission by bumping the counter — the check and the
    /// claim happen under one lock acquisition so a concurrent admission
    /// can't itself split the two apart. Returns `false` (leaving the
    /// counter untouched) if a different admission was detected — the
    /// caller's own admission already bumped it, and `run(...)` uses this
    /// to re-evaluate rather than trust a stale "looked safe" answer.
    private func tryClaimPrimaryQueueAdmission(unlessRacedSince expectedGeneration: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard primaryAdmissionGeneration == expectedGeneration else { return false }
        primaryAdmissionGeneration += 1
        return true
    }

    /// Claims primary-queue admission without checking against any prior
    /// snapshot — used by `.deny` (which never suspends between its
    /// snapshot and admission, so there is nothing to race-check against)
    /// and by the second-look path in the `.allow` branch above (which has
    /// already decided to proceed regardless of further churn).
    private func claimPrimaryQueueAdmissionUnconditionally() {
        lock.lock()
        primaryAdmissionGeneration += 1
        lock.unlock()
    }

    /// Answers "has the primary queue's current occupant been running
    /// longer than `allowGraceInterval`" — the short-grace-period check that
    /// lets an `.allow` call escape a stuck occupant well before that
    /// occupant's own full `timeout` deadline (and therefore well before
    /// `wedged` would naturally become true).
    ///
    /// Why a short threshold is safe, using the same reasoning that makes
    /// the `wedged`-true escape hatch safe (see the file header and
    /// `run(interaction:_:)` above): the trample risk is two closures alive
    /// at once, each free to write the process-global interaction flag,
    /// where one hasn't yet reached the point where its own
    /// `SecItemCopyMatching` call has consumed that flag. `enqueue(...)`
    /// calls `setInteractionAllowed` as the very first thing its closure
    /// does, before touching `primitives.copyMatching` at all — so
    /// `primaryOccupantSince` being set already means that call has been
    /// issued and its own flag value captured. The only remaining question
    /// is whether enough real time has passed that Security.framework's own
    /// internals have had a chance to actually read that flag before a
    /// second queue could change it again. A normal, successful background
    /// Keychain read (no dialog, no contention) completes in low
    /// milliseconds; `allowGraceInterval` (hundreds of ms by default) is
    /// generous headroom past that, while still being a small fraction of
    /// `timeout` (10s) — so a call that hasn't returned within the grace
    /// window has, for all practical purposes, already made it past the
    /// flag-capture point, exactly like a call that's missed its full
    /// deadline has. The margin is a judgment call, not a proof; if this
    /// turns out to be wrong, the failure mode is an occasional false
    /// "probably stuck" on a genuinely slow-but-fine read, not a
    /// use-after-flag-capture — that read still gets serialized correctly
    /// on `allowEscapeQueue` (which is itself serial), it's just not the
    /// queue that would have handled it under lighter load.
    ///
    /// Only ever consulted for `.allow` — `.deny` never waits on this and
    /// never marks occupancy differently; its fast-fail behavior is
    /// unchanged.
    private func primaryQueueProbablyStuck() async -> Bool {
        lock.lock()
        guard let occupantSince = primaryOccupantSince else {
            lock.unlock()
            return false
        }
        lock.unlock()

        let remainingGrace = allowGraceInterval - Date().timeIntervalSince(occupantSince)
        if remainingGrace <= 0 {
            // Already running longer than the grace period by the time we
            // even checked — no need to wait further. Re-read under the
            // lock: the occupant may have cleared between the unlocked
            // `Date()` computation above and now.
            lock.lock()
            let stillOccupied = primaryOccupantSince != nil
            lock.unlock()
            return stillOccupied
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let settled = Settled()
            lock.lock()
            guard primaryOccupantSince != nil else {
                lock.unlock()
                if settled.claim() { continuation.resume(returning: false) }
                return
            }
            primaryQueueWaiters.append {
                if settled.claim() { continuation.resume(returning: false) }
            }
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remainingGrace) {
                if settled.claim() { continuation.resume(returning: true) }
            }
        }
    }

    private func enqueue<T: Sendable>(
        on targetQueue: DispatchQueue,
        interaction: KeychainInteraction,
        clearsWedgeOnCompletion: Bool,
        tracksEscapeInFlight: Bool,
        marksPrimaryOccupancy: Bool,
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
                // Re-check, at actual execution time, the same guard `run()`
                // already applied at admission time. A `.deny` closure can
                // be sitting in the primary queue's backlog — already
                // admitted, not yet running — when `wedged` flips or an
                // escape call starts draining; `escapeCallsInFlight` (and
                // `wedged`) only gate NEW calls entering `run()`, they don't
                // reach back into a backlog that was built before either
                // went true. Without this, that already-queued `.deny`
                // closure would still call `setInteractionAllowed(false)`
                // below once its turn came, concurrently with an escape
                // closure's own flag writes — the exact trample this file's
                // serial design exists to prevent. Checked for `.deny`
                // only: `.allow` closures reaching the primary queue aren't
                // the ones this guard protects, and re-failing them here
                // would just contradict `run()`'s own admission decision
                // for no benefit.
                if interaction == .deny {
                    self?.lock.lock()
                    let isWedgedNow = self?.wedged ?? false
                    let hasDrainingEscapeCallsNow = (self?.escapeCallsInFlight ?? 0) > 0
                    self?.lock.unlock()
                    if isWedgedNow || hasDrainingEscapeCallsNow {
                        // This closure is dispatched to the primary queue
                        // (only primary-queue closures ever see
                        // `interaction == .deny` reach this point), so
                        // `clearsWedgeOnCompletion` is what normally proves
                        // the primary queue has drained past whatever set
                        // `wedged`. Bailing here WITHOUT that clear would
                        // strand `wedged == true` forever if this happens to
                        // be the last backlog item: reaching the top of a
                        // primary-queue closure's body already proves the
                        // queue drained past whatever set `wedged`, so a
                        // `wedged` seen here is by construction stale —
                        // safe, and necessary, to clear before bailing.
                        if clearsWedgeOnCompletion {
                            self?.lock.lock()
                            self?.wedged = false
                            self?.lock.unlock()
                        }
                        // `tracksEscapeInFlight` is never true for a `.deny`
                        // closure today (only escape-queue closures set it,
                        // and `.deny` never reaches the escape queue), so
                        // this is currently a no-op — kept explicit, mirroring
                        // the unconditional increment at admission above,
                        // so the pairing stays visible here rather than
                        // silently assumed. If a future `.deny` path ever DID
                        // reach the escape queue, skipping this decrement
                        // would leak the counter upward forever (the same
                        // class of permanent lockout `wedged` above guards
                        // against).
                        if tracksEscapeInFlight {
                            self?.lock.lock()
                            self?.escapeCallsInFlight -= 1
                            self?.lock.unlock()
                        }
                        if settled.claim() { continuation.resume(throwing: KeychainGatewayError.timedOut) }
                        return
                    }
                }
                // Marked at the very top of the closure, before the
                // interaction flag or `copyMatching` are touched at all —
                // `primaryQueueProbablyStuck()` relies on this timestamp
                // meaning "this call has genuinely started running," not
                // merely "was scheduled."
                if marksPrimaryOccupancy {
                    self?.lock.lock()
                    self?.primaryOccupantSince = Date()
                    self?.lock.unlock()
                }
                // Finding 1 (round 6): a non-consuming peek at whether THIS
                // call's own deadline timer (armed below, at admission
                // time, independent of whether this closure had even
                // started running yet) already fired while it was sitting
                // in the backlog. If it did, the caller already received
                // `.timedOut` — running `work()` now would silently mutate
                // the real Keychain long after the caller gave up (for a
                // write, potentially clobbering a NEWER write from a
                // subsequent successful retry with STALE data). Skip
                // straight to the unconditional bookkeeping below instead;
                // `settled.claim()` at the bottom will correctly return
                // `false` and no resume will happen either way, since the
                // deadline timer already claimed and resumed the
                // continuation with `.timedOut`.
                let outcome: Result<T, Error>
                if settled.peek() {
                    outcome = .failure(KeychainGatewayError.timedOut)
                } else {
                    primitives.setInteractionAllowed(interaction == .allow)
                    outcome = Result { try work() }
                    primitives.setInteractionAllowed(true)
                }
                if clearsWedgeOnCompletion {
                    self?.lock.lock()
                    self?.wedged = false
                    self?.lock.unlock()
                }
                // Cleared, and any `.allow` calls waiting on
                // `primaryQueueProbablyStuck()` released, on the closure's
                // own completion — same reasoning as `escapeCallsInFlight`'s
                // decrement below: this has to track when the underlying
                // `SecItemCopyMatching` call actually returns, not whether
                // some `async` caller already gave up at its own deadline.
                if marksPrimaryOccupancy {
                    self?.lock.lock()
                    self?.primaryOccupantSince = nil
                    let waiters = self?.primaryQueueWaiters ?? []
                    self?.primaryQueueWaiters = []
                    self?.lock.unlock()
                    waiters.forEach { $0() }
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
    /// Non-consuming check: has either side already claimed? Unlike
    /// `claim()`, calling this never itself counts as claiming — it exists
    /// so the work-side can ask "did my own deadline already win" without
    /// racing to become the side that delivers the final result. Only
    /// `claim()` decides who actually resumes the continuation.
    func peek() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }
}
