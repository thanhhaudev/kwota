//
//  StatsGranularity.swift
//  Kwota
//

import Foundation

/// Bucket size for the Stats time chart, chosen from how many calendar days the
/// selected window spans. Keeps bar density readable as "All time" grows: daily
/// bars up to ~3 months, then weekly, monthly, yearly — without dropping data.
enum StatsGranularity: Equatable {
    case day, week, month, year

    /// Pick the tier from the window's day count.
    /// ≤90 → day, ≤730 (~2y) → week, ≤3653 (~10y) → month, else year.
    static func forSpan(days: Int) -> StatsGranularity {
        switch days {
        case ..<91:   return .day
        case ..<731:  return .week
        case ..<3654: return .month
        default:      return .year
        }
    }

    /// Calendar unit for bucket-start truncation, the chart's `BarMark` unit, and
    /// the x-domain step.
    var component: Calendar.Component {
        switch self {
        case .day:   return .day
        case .week:  return .weekOfYear
        case .month: return .month
        case .year:  return .year
        }
    }

    /// Suffix for the "Avg X/…" readout.
    var avgUnit: String {
        switch self {
        case .day:   return "day"
        case .week:  return "week"
        case .month: return "month"
        case .year:  return "year"
        }
    }
}
