//
//  CompactUsageStatus.swift
//  Kwota
//
//  Turns the latest pace sample + a quota bucket into the single status tag a
//  compact row shows. Pure so every threshold and the projection math are
//  unit-testable without a SwiftUI host. Replaces the old "Recent pace" chart:
//  the pace graph collapses to one word, upgrading to a concrete time-to-cap
//  only when the current burn would exhaust the limit before it resets.
//

import Foundation

enum CompactUsageStatus {
    enum Style: Equatable {
        case calm       // steady — healthy
        case watch      // burning fast
        case hot        // projection / near cap
        case neutral    // cooling — benign, quiet
    }

    struct Tag: Equatable {
        let text: String
        let style: Style
    }

    /// Normalized pace (burn ÷ 24h baseline) word thresholds.
    static let burningFastPace: Double = 1.5
    static let coolingPace: Double = 0.5
    /// Ignore burn below this (%/hour) when projecting — avoids near-zero
    /// division and absurd "to cap" horizons.
    static let minBurnPerHour: Double = 0.1
    /// A level-only row with strictly less than this remaining shows "near cap".
    static let nearCapRemaining: Double = 15

    /// Session / weekly rows (history-backed). `nil` when there is no pace
    /// sample yet (first fetch / not enough history) → the row shows only its
    /// reset countdown.
    static func headlineTag(
        utilization: Double?,
        resetsAt: Date?,
        latest: CompactUsagePaceSeries.Point?,
        now: Date
    ) -> Tag? {
        guard let latest, let utilization else { return nil }
        let remaining = max(0, min(100, 100 - utilization))

        // Fresh (not history-derived) — trust it even if the pace sample below
        // is stale, so an exhausted window never reads as "cooling".
        if remaining <= 0 {
            return Tag(text: "at cap", style: .hot)
        }

        // `latest` comes from history, which only grows on a successful
        // fetch — a paused-polling gap (sleep, an outage, 429 backoff) can
        // leave it far behind `now`. Beyond the pace series' own "still
        // describes a useful average" bound, neither the burn rate nor the
        // pace word can be trusted for the current moment.
        guard now.timeIntervalSince(latest.at) <= CompactUsagePaceSeries.maximumAveragedGap else {
            return nil
        }

        if let resetsAt {
            // A reset marker already in the past belongs to a window this
            // burn rate predates — comparing against it would be meaningless.
            guard resetsAt > now else { return nil }

            if latest.burnPerHour > minBurnPerHour {
                let hoursToCap = remaining / latest.burnPerHour
                let exhaustion = now.addingTimeInterval(hoursToCap * 3600)
                if exhaustion < resetsAt {
                    return Tag(text: formatToCap(hoursToCap), style: .hot)
                }
            }
        }

        if latest.pace >= burningFastPace {
            return Tag(text: "burning fast", style: .watch)
        } else if latest.pace >= coolingPace {
            return Tag(text: "steady", style: .calm)
        } else {
            return Tag(text: "cooling", style: .neutral)
        }
    }

    /// Per-model / per-category rows (no history series). Level-only: a static
    /// "near cap" when little is left, otherwise no tag.
    static func levelTag(utilization: Double?) -> Tag? {
        guard let utilization else { return nil }
        let remaining = max(0, min(100, 100 - utilization))
        return remaining < nearCapRemaining ? Tag(text: "near cap", style: .hot) : nil
    }

    /// "~45m to cap" / "~3h to cap" / "~2d to cap". Never "0m" — clamps to 1.
    static func formatToCap(_ hours: Double) -> String {
        let minutes = hours * 60
        if minutes < 60 {
            return "~\(max(1, Int(minutes.rounded())))m to cap"
        } else if hours < 24 {
            return "~\(Int(hours.rounded()))h to cap"
        } else {
            return "~\(Int((hours / 24).rounded()))d to cap"
        }
    }
}
