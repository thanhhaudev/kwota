//
//  NotificationSettingsStore.swift
//  Kwota
//

import Foundation
import Observation

/// Loads and persists global `NotificationSettings`. Falls back to
/// `.default` on missing or corrupt files; failures to write are logged
/// but never thrown — the UI keeps the in-memory value.
@Observable
@MainActor
final class NotificationSettingsStore {
    private let fileURL: URL

    var value: NotificationSettings {
        didSet { persist() }
    }

    init(fileURL: URL = AppPaths.notificationSettingsFile) {
        self.fileURL = fileURL
        self.value = Self.load(from: fileURL) ?? .default
    }

    private static func load(from url: URL) -> NotificationSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(NotificationSettings.self, from: data)
        } catch {
            AppLog.shared.log(
                "NotificationSettingsStore.load failed: \(error)",
                level: .warn
            )
            return nil
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(value)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.shared.log(
                "NotificationSettingsStore.persist failed: \(error)",
                level: .warn
            )
        }
    }
}
