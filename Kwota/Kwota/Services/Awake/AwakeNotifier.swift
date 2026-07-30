//
//  AwakeNotifier.swift
//  Kwota

import AppKit
import Combine
import Foundation
import UserNotifications

enum AwakeStopReason: Equatable {
    case agentIdle(minutes: Int)
    case batteryBelowThreshold(current: Int, threshold: Int)
    case forceTimeoutElapsed
    case unexpectedExit   // caffeinate ended outside our control
    case watchdogStalled(heldMinutes: Int)
}

@MainActor
protocol AwakeNotifying: AnyObject {
    var isPermissionDenied: Bool { get }
    var isPermissionDeniedPublisher: AnyPublisher<Bool, Never> { get }
    func notifyStopped(_ reason: AwakeStopReason)

    /// Not an `AwakeStopReason`: that enum means "keep-awake ended", and this
    /// fires while the session is still running.
    func notifyLongUntimedSession(hours: Int)
}

@MainActor
final class UNAwakeNotifier: AwakeNotifying {
    @Published private(set) var isPermissionDenied: Bool = false
    var isPermissionDeniedPublisher: AnyPublisher<Bool, Never> {
        $isPermissionDenied.eraseToAnyPublisher()
    }

    private let center: UNUserNotificationCenter
    private var didRequestAuthorization = false
    private var becameActiveObserver: NSObjectProtocol?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        Task { @MainActor in await self.refreshPermissionStatus() }
        becameActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshPermissionStatus() }
        }
    }

    deinit {
        if let becameActiveObserver {
            NotificationCenter.default.removeObserver(becameActiveObserver)
        }
    }

    func notifyStopped(_ reason: AwakeStopReason) {
        Task { @MainActor in
            await ensureAuthorization()
            await refreshPermissionStatus()
            let content = UNMutableNotificationContent()
            content.title = "Kwota stopped keep-awake"
            content.body = Self.body(for: reason)
            let req = UNNotificationRequest(
                identifier: "awake.stopped.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(req)
            } catch {
                AppLog.shared.log("AwakeNotifier add failed: \(error)", level: .warn)
            }
        }
    }

    func notifyLongUntimedSession(hours: Int) {
        Task { @MainActor in
            await ensureAuthorization()
            await refreshPermissionStatus()
            let content = UNMutableNotificationContent()
            content.title = "Kwota is still keeping your Mac awake"
            content.body = "Kwota has kept your Mac awake for \(hours) hours on battery, "
                + "with no timeout or battery limit set."
            let req = UNNotificationRequest(
                identifier: "awake.untimed.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(req)
            } catch {
                AppLog.shared.log("AwakeNotifier untimed add failed: \(error)", level: .warn)
            }
        }
    }

    private func ensureAuthorization() async {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            AppLog.shared.log("AwakeNotifier auth failed: \(error)", level: .warn)
        }
    }

    private func refreshPermissionStatus() async {
        let settings = await center.notificationSettings()
        isPermissionDenied = settings.authorizationStatus == .denied
    }

    private static func body(for reason: AwakeStopReason) -> String {
        switch reason {
        case .agentIdle(let minutes):
            return "The agent has been idle for \(minutes) minute\(minutes == 1 ? "" : "s")."
        case .batteryBelowThreshold(let current, let threshold):
            return "Battery at \(current)%, below \(threshold)% threshold."
        case .forceTimeoutElapsed:
            return "Force keep-awake timeout elapsed."
        case .unexpectedExit:
            return "Caffeinate stopped unexpectedly."
        case .watchdogStalled(let minutes):
            return "Release timer stalled — keep-awake was force-released after \(minutes) minute\(minutes == 1 ? "" : "s")."
        }
    }
}
