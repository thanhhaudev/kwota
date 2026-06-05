//
//  UsageLevel.swift
//  Kwota
//

import SwiftUI

enum UsageLevel {
    static let warningThreshold: Double = 60
    static let criticalThreshold: Double = 80

    static func tint(for utilization: Double?) -> Color {
        guard let u = utilization else { return .secondary }
        if u >= criticalThreshold { return .red }
        if u >= warningThreshold  { return .yellow }
        return .green
    }
}
