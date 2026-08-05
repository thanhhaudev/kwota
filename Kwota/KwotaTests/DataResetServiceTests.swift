//
//  DataResetServiceTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class DataResetServiceTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwota-reset-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeKeychain() -> KeychainCredentialStore {
        KeychainCredentialStore(service: "com.thanhhaudev.Kwota.test.\(UUID())")
    }

    private func makeProfileStore(in tmp: URL, keychain: KeychainCredentialStore) -> ProfileStore {
        ProfileStore(
            profilesFile: tmp.appendingPathComponent("profiles.json"),
            keychain: keychain,
            profileDirectoryProvider: { id in tmp.appendingPathComponent(id.uuidString, isDirectory: true) }
        )
    }

    /// Stub that throws a chosen error from deleteAll(). Used to drive the
    /// "Keychain failure" branches without touching a real keychain.
    private struct ThrowingKeychain: KeychainWiping {
        let error: Error
        func deleteAll() async throws { throw error }
    }

    private enum StubError: Error, Equatable {
        case forced
    }

    // MARK: - Updated existing tests

    func test_wipeAll_clearsCredentialsForKnownProfiles() async throws {
        let tmp = try makeTempDir()
        let keychain = makeKeychain()
        let store = makeProfileStore(in: tmp, keychain: keychain)
        let suiteName = "kwota.tests.reset.profiles.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let idA = UUID()
        let idB = UUID()
        try store.add(Profile(id: idA, name: "A", authMethod: .cliSync))
        try store.add(Profile(id: idB, name: "B", authMethod: .sessionKey))
        // Seed credentials directly so we are testing keychain effect, not
        // ProfileStore.add's incidental writes.
        try await keychain.write(.sessionKey(value: "k-A"), for: idA)
        try await keychain.write(.sessionKey(value: "k-B"), for: idB)
        let seededA = try await keychain.read(for: idA)
        let seededB = try await keychain.read(for: idB)
        XCTAssertNotNil(seededA)
        XCTAssertNotNil(seededB)

        let svc = DataResetService()
        try await svc.wipeAll(
            keychain: keychain,
            appSupportPath: tmp,
            userDefaults: defaults,
            bundleIdentifier: suiteName
        )

        let clearedA = try await keychain.read(for: idA)
        let clearedB = try await keychain.read(for: idB)
        XCTAssertNil(clearedA)
        XCTAssertNil(clearedB)
    }

    func test_wipeAll_clearsInjectedUserDefaultsForGivenDomain() async throws {
        let suiteName = "kwota.tests.reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = "kwota.tests.resetServiceProbe"
        defaults.set("seeded", forKey: key)
        XCTAssertEqual(defaults.string(forKey: key), "seeded")

        let tmp = try makeTempDir()
        let svc = DataResetService()
        try await svc.wipeAll(
            keychain: makeKeychain(),
            appSupportPath: tmp,
            userDefaults: defaults,
            bundleIdentifier: suiteName
        )

        XCTAssertNil(defaults.string(forKey: key))
    }

    // MARK: - New tests

    /// Regression for the headline bug: a credential whose profile entry was
    /// lost (corrupt profiles.json, stale entry) must still be erased by reset.
    func test_wipeAll_clearsOrphanCredentialsNotInStore() async throws {
        let tmp = try makeTempDir()
        let keychain = makeKeychain()
        let orphanID = UUID()
        try await keychain.write(.sessionKey(value: "orphan"), for: orphanID)
        let seeded = try await keychain.read(for: orphanID)
        XCTAssertNotNil(seeded)

        let suiteName = "kwota.tests.reset.orphan.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let svc = DataResetService()
        try await svc.wipeAll(
            keychain: keychain,
            appSupportPath: tmp,
            userDefaults: defaults,
            bundleIdentifier: suiteName
        )

        let cleared = try await keychain.read(for: orphanID)
        XCTAssertNil(cleared)
    }

    func test_wipeAll_throwsWhenKeychainFails() async throws {
        let tmp = try makeTempDir()
        let suiteName = "kwota.tests.reset.throw.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let svc = DataResetService()
        do {
            try await svc.wipeAll(
                keychain: ThrowingKeychain(error: StubError.forced),
                appSupportPath: tmp,
                userDefaults: defaults,
                bundleIdentifier: suiteName
            )
            XCTFail("expected keychainFailed")
        } catch DataResetService.WipeError.keychainFailed {
            // expected
        } catch {
            XCTFail("expected keychainFailed, got \(error)")
        }
    }

    func test_wipeAll_throwsAppSupportFailed_whenRemoveFails() async throws {
        let tmp = try makeTempDir()
        let appSupport = tmp.appendingPathComponent("app-support")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let child = appSupport.appendingPathComponent("child")
        try Data("x".utf8).write(to: child)

        // Make the directory read-only (r-x) so removeItem on it fails — macOS
        // requires write+exec on the directory to delete its children.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o500))],
            ofItemAtPath: appSupport.path
        )
        defer {
            // Restore permissions so TempDirectory cleanup succeeds.
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: appSupport.path
            )
        }

        let suiteName = "kwota.tests.reset.appsupport.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("before-reset", forKey: "kwota.tests.appSupportProbe")

        let keychain = makeKeychain()
        let svc = DataResetService()

        do {
            try await svc.wipeAll(
                keychain: keychain,
                appSupportPath: appSupport,
                userDefaults: defaults,
                bundleIdentifier: suiteName
            )
            XCTFail("expected appSupportFailed")
        } catch DataResetService.WipeError.appSupportFailed {
            // expected
        } catch {
            XCTFail("expected appSupportFailed, got \(error)")
        }

        // UserDefaults must be cleared even though step 2 failed.
        XCTAssertNil(
            defaults.persistentDomain(forName: suiteName),
            "UserDefaults must be cleared even when App Support removal fails"
        )
    }

    /// Ordering invariant: a Keychain failure must abort BEFORE the
    /// destructive Application Support / UserDefaults steps run, so the user
    /// can retry without having lost their data.
    func test_wipeAll_doesNotTouchAppSupportWhenKeychainFails() async throws {
        let tmp = try makeTempDir()
        let sentinel = tmp.appendingPathComponent("sentinel.txt")
        try "still here".write(to: sentinel, atomically: true, encoding: .utf8)

        let suiteName = "kwota.tests.reset.order.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("still here", forKey: "kwota.tests.orderProbe")

        let svc = DataResetService()
        do {
            try await svc.wipeAll(
                keychain: ThrowingKeychain(error: StubError.forced),
                appSupportPath: tmp,
                userDefaults: defaults,
                bundleIdentifier: suiteName
            )
            XCTFail("expected wipeAll to throw")
        } catch {
            // expected
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinel.path),
            "AppSupport sentinel must survive a keychain-wipe failure"
        )
        XCTAssertEqual(defaults.string(forKey: "kwota.tests.orderProbe"), "still here",
                       "UserDefaults must survive a keychain-wipe failure")
    }

    /// Success path ordering: when keychain wipe succeeds, AppSupport is gone too.
    func test_wipeAll_clearsKeychainAndAppSupportOnSuccess() async throws {
        let tmp = try makeTempDir()
        let sentinel = tmp.appendingPathComponent("sentinel.txt")
        try "doomed".write(to: sentinel, atomically: true, encoding: .utf8)

        let keychain = makeKeychain()
        let id = UUID()
        try await keychain.write(.sessionKey(value: "doomed"), for: id)

        let suiteName = "kwota.tests.reset.success.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let svc = DataResetService()
        try await svc.wipeAll(
            keychain: keychain,
            appSupportPath: tmp,
            userDefaults: defaults,
            bundleIdentifier: suiteName
        )

        let cleared = try await keychain.read(for: id)
        XCTAssertNil(cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func test_wipeAll_removesWatchdogEvidenceFile() async throws {
        let tmp = try makeTempDir()
        let keychain = makeKeychain()
        let events = tmp.appendingPathComponent("awake-watchdog-events.json")
        try Data(#"{"records":[]}"#.utf8).write(to: events)
        XCTAssertTrue(FileManager.default.fileExists(atPath: events.path))

        let suiteName = "kwota.tests.reset.watchdog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let svc = DataResetService()
        try await svc.wipeAll(
            keychain: keychain,
            appSupportPath: tmp,
            userDefaults: defaults,
            bundleIdentifier: suiteName
        )

        // Reset removes the directory wholesale today, so this passes without
        // a production change. It exists so a future move to per-file deletion
        // cannot silently orphan the evidence trail.
        XCTAssertFalse(FileManager.default.fileExists(atPath: events.path))
    }
}
