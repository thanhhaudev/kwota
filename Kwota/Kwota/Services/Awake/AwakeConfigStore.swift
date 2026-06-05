//
//  AwakeConfigStore.swift
//  Kwota
//

import Foundation
import Observation

@MainActor
@Observable
final class AwakeConfigStore {
    private(set) var config: AwakeConfig

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    init(defaults: UserDefaults = .standard, key: String = AppStorageKeys.awakeConfig) {
        self.defaults = defaults
        self.key = key
        self.config = Self.load(defaults: defaults, key: key)
    }

    func update(_ newValue: AwakeConfig) {
        guard newValue != config else { return }
        config = newValue
        persist()
    }

    /// Mutate the current config via a closure; only persists when the value
    /// actually changes. Lets call sites do `store.mutate { $0.idleWindow = .m10 }`.
    func mutate(_ transform: (inout AwakeConfig) -> Void) {
        var copy = config
        transform(&copy)
        update(copy)
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(config)
            defaults.set(data, forKey: key)
        } catch {
            AppLog.shared.log("AwakeConfigStore encode failed: \(error)", level: .error)
        }
    }

    private static func load(defaults: UserDefaults, key: String) -> AwakeConfig {
        guard let data = defaults.data(forKey: key) else { return .default }
        do {
            return try JSONDecoder().decode(AwakeConfig.self, from: data)
        } catch {
            AppLog.shared.log("AwakeConfigStore decode failed (returning default): \(error)", level: .warn)
            return .default
        }
    }
}
