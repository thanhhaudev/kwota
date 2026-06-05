//
//  LoginItemController.swift
//  Kwota
//

import Foundation
import ServiceManagement

@MainActor
final class LoginItemController {
    enum Status {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
    }

    static let shared = LoginItemController()

    private init() {}

    var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled:           return .enabled
        case .notRegistered:     return .disabled
        case .notFound:          return .disabled
        case .requiresApproval:  return .requiresApproval
        @unknown default:        return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        AppLog.shared.log("LoginItemController.setEnabled(\(enabled)) ok", level: .info)
    }
}
