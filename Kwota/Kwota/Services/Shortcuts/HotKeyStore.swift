//
//  HotKeyStore.swift
//  Kwota
//

import Foundation

/// UserDefaults-backed storage for user-bound hotkeys, keyed by a
/// `name` string. Each definition is JSON-encoded under
/// `"hotkey.<name>"`. `nil` clears the entry.
final class HotKeyStore {
    private static let storagePrefix = "hotkey."
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func definition(for name: String) -> HotKeyDefinition? {
        guard let data = defaults.data(forKey: Self.key(name)) else { return nil }
        return try? decoder.decode(HotKeyDefinition.self, from: data)
    }

    func setDefinition(_ definition: HotKeyDefinition?, for name: String) {
        let key = Self.key(name)
        guard let definition else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? encoder.encode(definition) {
            defaults.set(data, forKey: key)
        }
    }

    func reset(_ name: String) {
        setDefinition(nil, for: name)
    }

    func names(withPrefix namePrefix: String) -> [String] {
        defaults.dictionaryRepresentation().keys.compactMap { key in
            guard key.hasPrefix(Self.storagePrefix) else { return nil }
            let name = String(key.dropFirst(Self.storagePrefix.count))
            guard name.hasPrefix(namePrefix) else { return nil }
            return name
        }
    }

    private static func key(_ name: String) -> String { "\(storagePrefix)\(name)" }
}
