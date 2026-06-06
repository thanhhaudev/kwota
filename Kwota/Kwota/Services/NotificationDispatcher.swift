//
//  NotificationDispatcher.swift
//  Kwota
//

import Foundation
import UserNotifications

/// Pure evaluator + (later) UNUserNotificationCenter shim. Keep evaluation
/// side-effect-free so it's directly testable; the side-effecting `dispatch`
/// path is added in a later task and skipped by tests.
@MainActor
final class NotificationDispatcher {
    enum Source: Equatable, Hashable {
        case session
        case weekly
    }

    enum RuleID: Equatable, Hashable {
        case session(Int)
        case weekly(Int)
        case reset(Source)
        case tokenExpiry(Date)
    }

    struct Intent: Equatable {
        let profileID: UUID
        let rule: RuleID
        let title: String
        let body: String
    }

    /// Per-profile in-memory dedup. Cleared for a `(profileID, source)` pair
    /// when a reset is detected for that source.
    private var firedRules: [UUID: Set<RuleID>] = [:]

    func evaluate(
        profile: Profile,
        current: ProviderUsageSummary?,
        previous: ProviderUsageSummary?,
        now: Date
    ) -> [Intent] {
        guard !profile.notificationsMuted, let current else { return [] }
        let cfg = (sessionThresholds: Set<Int>(), weeklyThresholds: Set<Int>(), notifyOnReset: false, notifyOnTokenExpiry: false)

        var intents: [Intent] = []
        var fired = firedRules[profile.id] ?? []

        // Reset detection (session)
        if didReset(prevUtil: previous?.primary?.utilization,
                    nextUtil: current.primary?.utilization) {
            // Clear all session.* fired flags
            fired = fired.filter { rule in
                if case .session = rule { return false }
                if case .reset(.session) = rule { return false }
                return true
            }
            if cfg.notifyOnReset {
                intents.append(makeIntent(profile: profile, rule: .reset(.session)))
            }
        }

        // Reset detection (weekly)
        if didReset(prevUtil: previous?.secondary?.utilization,
                    nextUtil: current.secondary?.utilization) {
            fired = fired.filter { rule in
                if case .weekly = rule { return false }
                if case .reset(.weekly) = rule { return false }
                return true
            }
            if cfg.notifyOnReset {
                intents.append(makeIntent(profile: profile, rule: .reset(.weekly)))
            }
        }

        // Threshold crossings
        for threshold in cfg.sessionThresholds.sorted() {
            let rule: RuleID = .session(threshold)
            if !fired.contains(rule),
               crossed(prev: previous?.primary?.utilization, next: current.primary?.utilization, threshold: threshold) {
                fired.insert(rule)
                intents.append(makeIntent(profile: profile, rule: rule))
            }
        }
        for threshold in cfg.weeklyThresholds.sorted() {
            let rule: RuleID = .weekly(threshold)
            if !fired.contains(rule),
               crossed(prev: previous?.secondary?.utilization, next: current.secondary?.utilization, threshold: threshold) {
                fired.insert(rule)
                intents.append(makeIntent(profile: profile, rule: rule))
            }
        }

        // Token expiry (CLI only)
        if cfg.notifyOnTokenExpiry,
           profile.authMethod == .cliSync,
           let expiresAt = profile.sessionKeyExpiresAt,
           expiresAt.timeIntervalSince(now) <= 24 * 3600,
           expiresAt > now,
           !fired.contains(.tokenExpiry(expiresAt)) {
            // Drop any previously-fired tokenExpiry rules with stale dates so the
            // dedup set doesn't grow unbounded as the token rotates.
            fired = fired.filter {
                if case .tokenExpiry = $0 { return false }
                return true
            }
            fired.insert(.tokenExpiry(expiresAt))
            intents.append(makeIntent(profile: profile, rule: .tokenExpiry(expiresAt)))
        }

        firedRules[profile.id] = fired
        return intents
    }

    // A reset is declared only when utilization drops sharply. Comparing
    // `resetsAt` was unreliable on rolling-window plans (the timestamp
    // advances as old usage ages off even though no new quota was granted).
    private func didReset(prevUtil: Double?, nextUtil: Double?) -> Bool {
        guard let prevUtil, let nextUtil else { return false }
        return prevUtil >= 30 && nextUtil < 5
    }

    private func crossed(prev: Double?, next: Double?, threshold: Int) -> Bool {
        guard let next else { return false }
        let p = prev ?? 0
        return p < Double(threshold) && next >= Double(threshold)
    }

    private func makeIntent(profile: Profile, rule: RuleID) -> Intent {
        Intent(
            profileID: profile.id,
            rule: rule,
            title: "Kwota — \(profile.name)",
            body: bodyText(for: rule, profile: profile)
        )
    }

    private func bodyText(for rule: RuleID, profile: Profile) -> String {
        switch rule {
        case .session(let pct): return "Session quota at \(pct)%."
        case .weekly(let pct):  return "Weekly quota at \(pct)%."
        case .reset(.session):  return "Session quota reset. Full quota available."
        case .reset(.weekly):   return "Weekly quota reset. Full quota available."
        case .tokenExpiry(let at):
            let hours = max(1, Int(at.timeIntervalSinceNow / 3600))
            return "CLI token expires in \(hours)h. Re-authenticate from Profiles."
        }
    }

    // MARK: - Side-effecting bridge to UNUserNotificationCenter

    /// Posts each intent as a non-grouped, immediate user notification.
    /// Silently no-ops if the user has not granted permission.
    func dispatch(_ intents: [Intent]) async {
        guard !intents.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        for intent in intents {
            let content = UNMutableNotificationContent()
            content.title = intent.title
            content.body = intent.body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: requestIdentifier(intent),
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                AppLog.shared.log("NotificationDispatcher.add failed: \(error)", level: .warn)
            }
        }
    }

    /// Posts a single one-off notification that isn't tied to a profile or
    /// quota rule — e.g. a background cache-AI evaluation finishing while the
    /// popover is closed. Reuses the same authorization grant as the quota
    /// alerts above; silently no-ops if the user hasn't granted permission.
    /// A stable `identifier` lets a later post for the same operation replace
    /// the earlier one rather than stack a second banner.
    func post(identifier: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            AppLog.shared.log("NotificationDispatcher.post failed: \(error)", level: .warn)
        }
    }

    /// Returns the current authorization status. Cheap; safe to poll on view
    /// `onAppear` to catch System Settings changes.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks for permission. Returns `true` iff `.alert` was granted.
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            AppLog.shared.log("requestAuthorization failed: \(error)", level: .warn)
            return false
        }
    }

    private func requestIdentifier(_ intent: Intent) -> String {
        switch intent.rule {
        case .session(let p):     return "kwota.\(intent.profileID).session.\(p)"
        case .weekly(let p):      return "kwota.\(intent.profileID).weekly.\(p)"
        case .reset(.session):    return "kwota.\(intent.profileID).reset.session"
        case .reset(.weekly):     return "kwota.\(intent.profileID).reset.weekly"
        case .tokenExpiry(let d): return "kwota.\(intent.profileID).tokenExpiry.\(Int(d.timeIntervalSince1970))"
        }
    }
}
