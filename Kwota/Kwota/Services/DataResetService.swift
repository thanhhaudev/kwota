//
//  DataResetService.swift
//  Kwota
//

import Foundation

/// Nuclear "Reset all data" orchestrator. Runs once, just before
/// `NSApp.terminate(nil)`, so any in-flight task is cut off by the runloop
/// ending rather than by careful sequencing here.
@MainActor
final class DataResetService {

    enum WipeError: Error {
        case keychainFailed(Error)
        case appSupportFailed(Error)
    }

    /// Wipes every byte Kwota owns:
    /// 1. Every credential under the production Keychain service.
    /// 2. The Application Support root (logs, profile dirs, partial state).
    /// 3. UserDefaults persistent domain for the given bundle id.
    ///
    /// Step 1 runs first and throws `WipeError.keychainFailed` on failure;
    /// nothing else is touched. Step 2 throws `WipeError.appSupportFailed`
    /// if the directory remove fails — the keychain is already wiped at
    /// that point so the user has lost their credential storage and needs
    /// to know that App Support may still contain leftover files. Step 3
    /// runs even after a step 2 failure because UserDefaults removal
    /// itself does not throw.
    ///
    /// `appSupportPath`, `userDefaults`, and `bundleIdentifier` default to
    /// production values so production callers stay untouched. Tests MUST
    /// override all three — otherwise step 2 deletes the user's real
    /// Application Support tree, and step 3 wipes the user's real
    /// UserDefaults domain.
    func wipeAll(
        keychain: any KeychainWiping,
        appSupportPath: URL = AppPaths.applicationSupportDirectory,
        userDefaults: UserDefaults = .standard,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws {
        // 1. Keychain — first, and throws on failure so nothing else is touched.
        do {
            try keychain.deleteAll()
        } catch {
            throw WipeError.keychainFailed(error)
        }

        // 2. Application Support catch-all (profile dirs, logs, cache).
        //    Collect any failure and throw after UserDefaults is cleared.
        var appSupportError: Error?
        if FileManager.default.fileExists(atPath: appSupportPath.path) {
            do {
                try FileManager.default.removeItem(at: appSupportPath)
            } catch {
                appSupportError = error
            }
        }

        // 3. UserDefaults — runs even on App Support failure so the user's
        //    preferences are always cleared regardless of filesystem state.
        if let domain = bundleIdentifier {
            userDefaults.removePersistentDomain(forName: domain)
            userDefaults.synchronize()
        }

        if let appSupportError {
            throw WipeError.appSupportFailed(appSupportError)
        }
    }
}
