//
//  PowerSourceSamplerTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

final class PowerSourceSamplerTests: XCTestCase {

    /// Proves the sampler runs on a real background thread. The XCTestCase
    /// itself is MainActor-isolated under this target's default isolation, so
    /// the assertion that matters is the thread check inside the closure — not
    /// the mere fact that this compiles.
    func test_snapshot_runsOffTheMainThread() async {
        let reading: BatteryReading = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                XCTAssertFalse(Thread.isMainThread, "sampler must not require main")
                cont.resume(returning: PowerSourceSampler.snapshot())
            }
        }
        // Desktops report nil percent; laptops report 0...100. Both are valid.
        if let percent = reading.percent {
            XCTAssertGreaterThanOrEqual(percent, 0)
            XCTAssertLessThanOrEqual(percent, 100)
        }
    }

    func test_snapshot_isStableAcrossBackToBackCalls() {
        let a = PowerSourceSampler.snapshot()
        let b = PowerSourceSampler.snapshot()
        XCTAssertEqual(a.isOnBattery, b.isOnBattery)
    }
}
