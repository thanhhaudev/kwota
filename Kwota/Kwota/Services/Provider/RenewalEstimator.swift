//  RenewalEstimator.swift
//  Kwota
//
//  Pure date math for the renewal/reset estimate shown in the switcher
//  subtitle and Usage-tab header. No IO, no @MainActor — safe to call
//  from anywhere. Shared by MenuBarViewModel (subscription estimate) and
//  the AccountProvider.renewalEstimate hook.

import Foundation

enum RenewalEstimator {
    /// Roll `anchor` forward by whole months until it is in the future
    /// relative to `now`. Returns the anchor unchanged when already future.
    /// Defensive 600-iteration cap (~50 years) guards against a Calendar
    /// returning nil or a non-advancing date — we'd rather render nothing
    /// than hang the UI thread.
    static func next(after anchor: Date, now: Date) -> Date? {
        let cal = Calendar.current
        var next = anchor
        guard next <= now else { return next }
        var iterations = 0
        while next <= now {
            iterations += 1
            if iterations > 600 {
                AppLog.shared.log(
                    "RenewalEstimator.next: monthly extrapolation exceeded 600 iterations from \(anchor) — clamping to nil",
                    level: .warn
                )
                return nil
            }
            guard let bumped = cal.date(byAdding: .month, value: 1, to: next) else { break }
            next = bumped
        }
        return next
    }

    /// Subscription renewal estimate: an explicit `subscriptionRenewsAt`
    /// (e.g. Codex billing-period-end) wins; otherwise extrapolate monthly
    /// from `subscriptionCreatedAt` (Claude). nil when neither exists.
    static func subscription(for profile: Profile, now: Date) -> Date? {
        if let explicit = profile.subscriptionRenewsAt { return explicit }
        guard let start = profile.subscriptionCreatedAt else { return nil }
        return next(after: start, now: now)
    }

    /// Decide the new persisted anchor given a freshly `detected` boundary
    /// and the `stored` one. Returns the value to persist, or nil to leave
    /// the stored value untouched (nothing detected, or not newer — so a
    /// trimmed history can't move the anchor backwards).
    static func adopt(detected: Date?, over stored: Date?) -> Date? {
        guard let detected else { return nil }
        if let stored, detected <= stored { return nil }
        return detected
    }

    /// Abbreviated absolute date, e.g. "6 Jun 2026".
    static func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Switcher subtitle fragment: "<prefix> <abbrev date>" for absolute
    /// estimates, "<prefix> <relative>" for relative-only ones.
    static func subtitleString(_ est: RenewalEstimate, now: Date = Date()) -> String {
        est.absolute
            ? "\(est.prefix) \(formattedDate(est.date))"
            : "\(est.prefix) \(RelativeFormatters.full.localizedString(for: est.date, relativeTo: now))"
    }

    /// Usage-header line: absolute adds a "· <relative>" hint; relative-only
    /// shows just "<prefix> <relative>".
    static func headerString(_ est: RenewalEstimate, now: Date = Date()) -> String {
        let rel = RelativeFormatters.full.localizedString(for: est.date, relativeTo: now)
        return est.absolute ? "\(est.prefix) \(formattedDate(est.date)) · \(rel)"
                            : "\(est.prefix) \(rel)"
    }
}
