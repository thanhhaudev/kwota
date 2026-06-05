//
//  AwakeFormatters.swift
//  Kwota
//

import Foundation

enum AwakeFormatters {
    /// "1h 02m 03s" when ≥1h, otherwise "2m 03s". Shared between the Awake
    /// Status card subtitle and the Awake Mode card timer.
    static func formatHMS(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, sec) }
        return String(format: "%dm %02ds", m, sec)
    }
}
