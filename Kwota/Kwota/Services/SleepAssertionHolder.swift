//
//  SleepAssertionHolder.swift
//  Kwota
//
//  Thin wrapper over IOKit power-management assertions. Kwota holds these
//  assertions itself (no child process); the kernel tracks them in its
//  per-process table and releases them on any Kwota exit — crash, SIGKILL,
//  reboot, graceful quit. This replaces the previous `/usr/bin/caffeinate`
//  child whose orphans could outlive Kwota and pin the Mac awake forever.
//

import Foundation
import IOKit
import IOKit.pwr_mgt

/// Opaque token returned by `acquire`, passed to `release`. Holds the raw
/// `IOPMAssertionID` plus a tag for logging/debugging.
struct SleepAssertion: Equatable {
    let id: UInt32                  // IOPMAssertionID is UInt32
    let type: SleepAssertionType
}

enum SleepAssertionType: String, Equatable, CaseIterable {
    case preventDisplaySleep
    case preventIdleSleep
    case preventSystemSleep

    /// The IOKit assertion type string. Apple defines these as `String`
    /// constants in `IOKit.pwr_mgt`; passing the right one to
    /// `IOPMAssertionCreateWithName` is the entire contract.
    var iokitTypeString: String {
        switch self {
        case .preventDisplaySleep: return kIOPMAssertionTypePreventUserIdleDisplaySleep
        case .preventIdleSleep:    return kIOPMAssertionTypePreventUserIdleSystemSleep
        case .preventSystemSleep:  return kIOPMAssertionTypePreventSystemSleep
        }
    }
}

enum SleepAssertionError: Error {
    /// `IOPMAssertionCreateWithName` returned a non-success `IOReturn`.
    /// The raw status is captured so logs/Console.app can decode it
    /// (e.g., `0xe00002bd` = kIOReturnNotPermitted).
    case acquireFailed(type: SleepAssertionType, status: Int32)
}

/// Test seam. The single-responsibility surface `CaffeinateManager` depends on.
/// Not `Sendable`; the production manager is `@MainActor` and always calls
/// the holder on the main actor.
protocol SleepAssertionHolder {
    func acquire(_ type: SleepAssertionType, name: String) throws -> SleepAssertion
    func release(_ assertion: SleepAssertion)
    /// Calls `IOPMAssertionDeclareUserActivity` — a one-shot "user is active"
    /// tap that resets the idle timer. Not stored as a persistent assertion;
    /// no token to release.
    func declareUserActivity(name: String)
}

final class IOKitSleepAssertionHolder: SleepAssertionHolder {

    func acquire(_ type: SleepAssertionType, name: String) throws -> SleepAssertion {
        var assertionID: IOPMAssertionID = 0
        let status: IOReturn = IOPMAssertionCreateWithName(
            type.iokitTypeString as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &assertionID
        )
        guard status == kIOReturnSuccess else {
            throw SleepAssertionError.acquireFailed(type: type, status: status)
        }
        return SleepAssertion(id: assertionID, type: type)
    }

    func release(_ assertion: SleepAssertion) {
        IOPMAssertionRelease(assertion.id)
    }

    func declareUserActivity(name: String) {
        var ignored: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity(
            name as CFString,
            kIOPMUserActiveLocal,
            &ignored
        )
    }
}
