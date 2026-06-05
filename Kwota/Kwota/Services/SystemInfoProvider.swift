//
//  SystemInfoProvider.swift
//  Kwota
//

import Foundation

struct SystemSnapshot: Equatable {
    struct ProviderCLI: Equatable, Identifiable {
        let providerIDRaw: String
        let displayName: String
        let version: String?
        var id: String { providerIDRaw }
    }

    let macOSVersion: String
    let providerCLIs: [ProviderCLI]
}

enum SystemInfoProvider {
    static func macOSVersionString(from v: OperatingSystemVersion) -> String {
        "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    @MainActor
    static func snapshot(registry: ProviderRegistry) async -> SystemSnapshot {
        let macOS = macOSVersionString(from: ProcessInfo.processInfo.operatingSystemVersion)

        let providers = registry.all.map {
            (idRaw: $0.id.rawValue, displayName: $0.displayName, ref: $0)
        }

        let versions: [(String, String, String?)] = await withTaskGroup(
            of: (Int, String, String, String?).self
        ) { group in
            for (index, entry) in providers.enumerated() {
                let provider = entry.ref
                let idRaw = entry.idRaw
                let displayName = entry.displayName
                group.addTask { @MainActor in
                    let v = await provider.cliVersion()
                    return (index, idRaw, displayName, v)
                }
            }
            var collected: [(Int, String, String, String?)] = []
            for await result in group { collected.append(result) }
            collected.sort { $0.0 < $1.0 }
            return collected.map { ($0.1, $0.2, $0.3) }
        }

        let clis = versions.map {
            SystemSnapshot.ProviderCLI(providerIDRaw: $0.0, displayName: $0.1, version: $0.2)
        }

        return SystemSnapshot(
            macOSVersion: macOS,
            providerCLIs: clis
        )
    }
}
