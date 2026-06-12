//
//  AgentProcessInfoTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class AgentProcessInfoTests: XCTestCase {

    private func proc(cpu: Double) -> AgentProcessInfo {
        AgentProcessInfo(
            pid: 100,
            ppid: 500,
            provider: .claude,
            commandDisplay: "claude",
            cpuPercent: cpu,
            elapsed: "01:00"
        )
    }

    func test_activityTier_boundaries() {
        XCTAssertEqual(proc(cpu: 0.0).activityTier, .idle)
        XCTAssertEqual(proc(cpu: 1.9).activityTier, .idle)
        XCTAssertEqual(proc(cpu: 2.0).activityTier, .active)
        XCTAssertEqual(proc(cpu: 29.9).activityTier, .active)
        XCTAssertEqual(proc(cpu: 30.0).activityTier, .busy)
        XCTAssertEqual(proc(cpu: 312.5).activityTier, .busy)
    }

    func test_activityTier_ordering() {
        // Comparable drives the busy-first list sort in the VM.
        XCTAssertLessThan(AgentProcessInfo.ActivityTier.idle, .active)
        XCTAssertLessThan(AgentProcessInfo.ActivityTier.active, .busy)
    }
}
