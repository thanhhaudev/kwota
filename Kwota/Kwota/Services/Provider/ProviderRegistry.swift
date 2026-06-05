//
//  ProviderRegistry.swift
//  Kwota
//

import Foundation

/// Holds all registered `AccountProvider`s. Constructed once at app launch
/// in `KwotaApp.init` and passed into `MenuBarViewModel`. Test code creates
/// fresh instances and injects stub providers.
@MainActor
@Observable
final class ProviderRegistry {
    private(set) var all: [any AccountProvider] = []
    private var byID: [String: any AccountProvider] = [:]

    func register(_ provider: any AccountProvider) {
        let key = provider.id.rawValue
        if byID[key] == nil {
            all.append(provider)
        } else if let idx = all.firstIndex(where: { $0.id.rawValue == key }) {
            all[idx] = provider
        }
        byID[key] = provider
    }

    func provider(for id: ProviderID) -> (any AccountProvider)? {
        byID[id.rawValue]
    }
}
