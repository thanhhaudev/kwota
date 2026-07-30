//
//  OffMainIOKitContractTests.swift
//  KwotaTests
//
//  Contract tests against macOS itself, not against Kwota. `AwakeWatchdog`
//  releases power assertions and samples the battery from a background queue;
//  if either API silently misbehaves off-main the watchdog reports success
//  while the Mac stays awake. These run in `make test` rather than living as a
//  manual smoke test a future contributor can skip.
//

import XCTest
import IOKit
import IOKit.pwr_mgt
@testable import Kwota

final class OffMainIOKitContractTests: XCTestCase {

    /// Looks the assertion up by NAME, not by id. `IOPMCopyAssertionsByProcess`
    /// yields dictionaries keyed by `kIOPMAssertionNameKey` / `kIOPMAssertionTypeKey`;
    /// there is no public key carrying the `IOPMAssertionID`, so a unique name is
    /// the only way to find one specific assertion.
    ///
    /// Note the real signature: `IOReturn IOPMCopyAssertionsByProcess(CFDictionaryRef *)`
    /// — an out-parameter plus a non-optional `IOReturn`. It does not return an
    /// optional you can chain onto.
    private func assertionIsHeld(named name: String) -> Bool {
        var out: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess,
              let raw = out?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return false }
        let pid = NSNumber(value: ProcessInfo.processInfo.processIdentifier)
        guard let mine = raw[pid] else { return false }
        return mine.contains { ($0[kIOPMAssertionNameKey as String] as? String) == name }
    }

    @MainActor
    func test_assertionAcquiredOnMain_isReleasedFromBackgroundQueue() async throws {
        let name = "KwotaTests contract \(UUID().uuidString)"
        let holder = IOKitSleepAssertionHolder()
        let assertion = try holder.acquire(.preventIdleSleep, name: name)
        // Belt-and-braces: a failing assertion below must never leave a real
        // power assertion held on the developer's machine.
        defer { _ = IOPMAssertionRelease(assertion.id) }

        XCTAssertTrue(assertionIsHeld(named: name), "precondition: assertion should be held")

        let status: IOReturn = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .default).async {
                cont.resume(returning: IOPMAssertionRelease(assertion.id))
            }
        }

        XCTAssertEqual(status, kIOReturnSuccess, "off-main release must succeed")
        XCTAssertFalse(assertionIsHeld(named: name), "off-main release must actually drop it")
    }

    func test_powerSourceSample_offMain_matchesOnMain() async {
        let onMain = PowerSourceSampler.snapshot()
        let offMain: BatteryReading = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .default).async {
                cont.resume(returning: PowerSourceSampler.snapshot())
            }
        }
        XCTAssertEqual(onMain.isOnBattery, offMain.isOnBattery)
        if let a = onMain.percent, let b = offMain.percent {
            // One sample can straddle a real percentage change.
            XCTAssertLessThanOrEqual(abs(a - b), 1)
        } else {
            XCTAssertNil(onMain.percent)
            XCTAssertNil(offMain.percent)
        }
    }
}
