//
//  FileSystemEventStreamTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class FileSystemEventStreamTests: XCTestCase {
    private let pollStep: TimeInterval = 0.05
    private let pollLimit: TimeInterval = 3.0

    func test_observe_emitsOnWrite() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("watched.json")
        try Data("v1".utf8).write(to: file)

        let counter = EventCounter()
        let stream = FileSystemEventStream.observe(
            path: file.path,
            queueLabel: "test.observe.write"
        )
        let consumer = Task {
            for await _ in stream { await counter.bump() }
        }
        defer { consumer.cancel() }

        try await Task.sleep(nanoseconds: 200_000_000)
        try Data("v2".utf8).write(to: file)
        try await waitUntil { await counter.get() >= 1 }
    }

    func test_observe_reArmsAfterAtomicRename() async throws {
        // Guards against the bug where a temp-then-rename leaves the kqueue fd
        // bound to the old (unlinked) inode and subsequent writes to the path
        // fire no events. The stream must follow the path across the rename.
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("watched.json")
        try Data("v1".utf8).write(to: file)

        let counter = EventCounter()
        let stream = FileSystemEventStream.observe(
            path: file.path,
            queueLabel: "test.observe.rename",
            reopenBackoff: 0.02
        )
        let consumer = Task {
            for await _ in stream { await counter.bump() }
        }
        defer { consumer.cancel() }

        try await Task.sleep(nanoseconds: 200_000_000)

        let temp = dir.appendingPathComponent("watched.json.tmp")
        try Data("v2".utf8).write(to: temp)
        try FileManager.default.replaceItem(
            at: file,
            withItemAt: temp,
            backupItemName: nil,
            options: [],
            resultingItemURL: nil
        )
        try await waitUntil { await counter.get() >= 1 }

        // Give the re-arm a beat to bind the new fd before the post-rename
        // write, so the kqueue source is live when we modify the file again.
        try await Task.sleep(nanoseconds: 250_000_000)
        let baseline = await counter.get()
        try Data("v3".utf8).write(to: file)
        try await waitUntil { await counter.get() > baseline }
    }

    private func waitUntil(
        _ predicate: @Sendable () async -> Bool,
        file: StaticString = #file,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(pollLimit)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: UInt64(pollStep * 1_000_000_000))
        }
        XCTFail("waitUntil timed out", file: file, line: line)
    }
}

private actor EventCounter {
    private var count = 0
    func bump() { count += 1 }
    func get() -> Int { count }
}

private enum TempDir {
    static func make() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fseventstream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
