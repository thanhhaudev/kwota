//
//  StubKeychainGateway.swift
//  KwotaTests
//
//  Shared `KeychainGateways` test double, standing in for the old
//  `CLICredentialReader.keychainProbe` closure seam now that the reader
//  talks to the gateway instead of Security.framework directly.
//

import Foundation
@testable import Kwota

nonisolated final class StubKeychainGateway: KeychainGateways, @unchecked Sendable {
    private let lock = NSLock()
    private var probe: () -> Data?
    private var _lastInteraction: KeychainInteraction?
    private var _readCount = 0

    var lastInteraction: KeychainInteraction? {
        lock.lock(); defer { lock.unlock() }; return _lastInteraction
    }
    var readCount: Int {
        lock.lock(); defer { lock.unlock() }; return _readCount
    }

    init(read probe: @escaping () -> Data? = { nil }) {
        self.probe = probe
    }

    /// Runs `probe` off the main thread via `OffMain.run`, mirroring the real
    /// `KeychainGateway` — tests that inject a slow/blocking probe (standing in
    /// for an unanswered consent dialog) get the same off-main behaviour the
    /// production gateway provides, instead of blocking whatever thread the
    /// Swift concurrency runtime happened to pick for this `async` call.
    func read(service: String, account: String?, interaction: KeychainInteraction) async throws -> Data? {
        lock.lock()
        _readCount += 1
        _lastInteraction = interaction
        let probe = self.probe
        lock.unlock()
        return await OffMain.run { probe() }
    }

    func write(_ data: Data, service: String, account: String) async throws {}
    func delete(service: String, account: String) async throws {}
    func deleteAll(service: String) async throws {}
}
