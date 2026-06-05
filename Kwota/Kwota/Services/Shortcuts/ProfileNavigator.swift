//
//  ProfileNavigator.swift
//  Kwota
//

import Foundation

enum ProfileNavigator {
    static func nextProfileID(from activeProfileID: UUID?, in profiles: [Profile]) -> UUID? {
        targetProfileID(moving: 1, from: activeProfileID, in: profiles)
    }

    static func previousProfileID(from activeProfileID: UUID?, in profiles: [Profile]) -> UUID? {
        targetProfileID(moving: -1, from: activeProfileID, in: profiles)
    }

    private static func targetProfileID(
        moving delta: Int,
        from activeProfileID: UUID?,
        in profiles: [Profile]
    ) -> UUID? {
        guard profiles.count > 1 else { return nil }

        if let activeProfileID,
           let currentIndex = profiles.firstIndex(where: { $0.id == activeProfileID }) {
            let nextIndex = (currentIndex + delta + profiles.count) % profiles.count
            return profiles[nextIndex].id
        }

        return delta > 0 ? profiles.first?.id : profiles.last?.id
    }
}
