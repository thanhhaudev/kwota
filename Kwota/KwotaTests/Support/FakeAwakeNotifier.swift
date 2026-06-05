//
//  FakeAwakeNotifier.swift
//  KwotaTests

import Foundation
import Combine
@testable import Kwota

@MainActor
final class FakeAwakeNotifier: AwakeNotifying {
    @Published var isPermissionDenied: Bool = false
    var isPermissionDeniedPublisher: AnyPublisher<Bool, Never> {
        $isPermissionDenied.eraseToAnyPublisher()
    }
    private(set) var calls: [AwakeStopReason] = []
    func notifyStopped(_ reason: AwakeStopReason) {
        calls.append(reason)
    }
}
