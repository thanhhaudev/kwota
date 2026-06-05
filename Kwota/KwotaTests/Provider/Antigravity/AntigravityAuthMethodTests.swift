import XCTest
@testable import Kwota

@MainActor
final class AntigravityAuthMethodTests: XCTestCase {
    final class FakeWatcher: AntigravityProcessWatching {
        var onChange: ((AntigravityIdentity?) -> Void)?
        var current: AntigravityIdentity?
        func start() {}
        func stop() {}
        func pokeNow() {}
        func popoverDidOpen() {}
        func popoverDidClose() {}
    }

    func test_isAvailable_reflectsWatcherCurrent() {
        let watcher = FakeWatcher()
        let method = AntigravityAuthMethod(watcher: watcher)
        XCTAssertFalse(method.isAvailable)
        XCTAssertTrue(method.displayCaption.contains("Open Antigravity"))

        watcher.current = AntigravityIdentity(
            csrfToken: "t", port: 1234, credentialFingerprint: "fp"
        )
        XCTAssertTrue(method.isAvailable)
        XCTAssertTrue(method.displayCaption.contains("Detected"))
    }

    func test_kindAndDisplayMetadata() {
        let method = AntigravityAuthMethod(watcher: FakeWatcher())
        XCTAssertEqual(method.kind, .cliSync)
        XCTAssertEqual(method.displayTitle, "Use Antigravity app")
        XCTAssertFalse(method.systemImage.isEmpty)
    }
}
