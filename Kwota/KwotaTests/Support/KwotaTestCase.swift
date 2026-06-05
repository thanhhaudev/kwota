//
//  KwotaTestCase.swift
//  KwotaTests
//
//  Opt-in base class for new tests. Provides per-test isolation primitives
//  plus a URLProtocol net guard, so accidental contact with real user data
//  or real APIs becomes a test failure instead of silent damage.
//
//  Provides:
//    • A per-test TempDirectory at `tempDir`
//    • UUID-namespaced Keychain stores via `makeKeychain()`
//    • Per-test UserDefaults suites via `makeUserDefaults()`
//    • An installed URLProtocolNetGuard that fails the test if real
//      (non-file://) network traffic is attempted via URLSession.
//
//  Existing XCTestCase tests do not need to migrate; this class is for
//  new tests and for tests that touch network/Keychain surfaces.
//
//  ===== TEST ISOLATION RULE =====
//
//  Tests must not touch real user data or hit real APIs. The defaults
//  are hardened so production resources are only reachable via explicit
//  `.live()` factories — do not undo this.
//
//    • Network: never call `ClaudeAPIClient.live()` from tests.
//      Construct `ClaudeAPIClient(transport:)` with a stub closure that
//      returns a `(Data, HTTPURLResponse)` tuple.
//    • Keychain: never call `KeychainCredentialStore.live()` from tests.
//      Use a UUID-namespaced service — `makeKeychain()` below already
//      does this. Clean up in tearDown with `keychain.deleteAll()` if
//      the test wrote multiple entries.
//    • Filesystem: write under `TempDirectory()` only. Do not touch
//      `~/.claude`, `AppPaths.applicationSupportDirectory`, or
//      `NSHomeDirectory()`.
//    • UserDefaults: use `UserDefaults(suiteName:)` with a unique name;
//      never mutate `UserDefaults.standard`. `makeUserDefaults()` below
//      already does this.
//    • Subprocess: use `MockProcessLauncher`. Never call
//      `/usr/bin/caffeinate` or the real `claude` CLI.
//

import XCTest
@testable import Kwota

@MainActor
class KwotaTestCase: XCTestCase {

    private(set) var tempDir: TempDirectory!
    private var createdSuiteNames: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        tempDir = TempDirectory()
        URLProtocolNetGuard.install()
    }

    override func tearDown() async throws {
        URLProtocolNetGuard.uninstall()
        for suite in createdSuiteNames {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        createdSuiteNames.removeAll()
        tempDir = nil
        try await super.tearDown()
    }

    /// Returns a `KeychainCredentialStore` keyed under a unique test
    /// service. Caller is responsible for `try? store.deleteAll()` in
    /// tearDown if many entries are written; for one-off use the
    /// per-test UUID isolates keys naturally.
    func makeKeychain() -> KeychainCredentialStore {
        KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID().uuidString)")
    }

    /// Returns a `UserDefaults` instance backed by a unique suite. The
    /// suite is removed in tearDown.
    func makeUserDefaults(name: String = "kwota.test") -> UserDefaults {
        let suite = "\(name).\(UUID().uuidString)"
        createdSuiteNames.append(suite)
        return UserDefaults(suiteName: suite)!
    }
}
