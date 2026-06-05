//
//  MockSleepAssertionHolder.swift
//  KwotaTests
//

import Foundation
@testable import Kwota

/// Test double. Records every `acquire`/`release`/`declareUserActivity`
/// call. Use `nextAcquireError` to drive the partial-acquire rollback test.
final class MockSleepAssertionHolder: SleepAssertionHolder {
    struct AcquireRecord: Equatable {
        let type: SleepAssertionType
        let name: String
    }

    private(set) var acquired: [AcquireRecord] = []
    private(set) var released: [SleepAssertion] = []
    private(set) var declareUserActivityCount: Int = 0

    /// If set, the next `acquire` throws this error and clears the field.
    var nextAcquireError: Error?

    private var nextID: UInt32 = 1

    func acquire(_ type: SleepAssertionType, name: String) throws -> SleepAssertion {
        if let err = nextAcquireError {
            nextAcquireError = nil
            throw err
        }
        let assertion = SleepAssertion(id: nextID, type: type)
        nextID += 1
        acquired.append(AcquireRecord(type: type, name: name))
        return assertion
    }

    func release(_ assertion: SleepAssertion) {
        released.append(assertion)
    }

    func declareUserActivity(name: String) {
        declareUserActivityCount += 1
    }
}
