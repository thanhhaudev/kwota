//
//  UsageHistoryEntry.swift
//  Kwota
//

import Foundation

struct UsageHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let at: Date
    let fiveHour: Double?
    let sevenDay: Double?

    init(id: UUID = UUID(), at: Date, fiveHour: Double?, sevenDay: Double?) {
        self.id = id
        self.at = at
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}
