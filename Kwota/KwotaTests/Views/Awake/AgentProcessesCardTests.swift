//
//  AgentProcessesCardTests.swift
//  KwotaTests
//

import XCTest
@testable import Kwota

@MainActor
final class AgentProcessesCardTests: XCTestCase {

    private func proc(_ pid: Int32, orphan: Bool) -> AgentProcessInfo {
        AgentProcessInfo(
            pid: pid,
            ppid: orphan ? 1 : 500,
            provider: .claude,
            commandDisplay: "claude",
            cpuPercent: 0.0,
            elapsed: "01:00"
        )
    }

    /// VM hands the model an orphans-first sorted list; fixtures mirror that.
    private func fixture(orphans: Int, live: Int) -> [AgentProcessInfo] {
        (0..<orphans).map { proc(Int32(100 + $0), orphan: true) }
            + (0..<live).map { proc(Int32(200 + $0), orphan: false) }
    }

    func test_visible_underCap_returnsAll() {
        let all = fixture(orphans: 1, live: 3)
        XCTAssertEqual(AgentProcessListModel.visible(all, showAll: false), all)
    }

    func test_visible_overCap_capsTotalRows_orphansFirst() {
        let all = fixture(orphans: 2, live: 14)
        let visible = AgentProcessListModel.visible(all, showAll: false)
        // Total cap: input is orphans-first sorted, so orphans get priority
        // within the cap; the rest is reachable behind Show all.
        XCTAssertEqual(visible.map(\.pid), [100, 101, 200, 201, 202])
        XCTAssertEqual(visible.count, AgentProcessListModel.collapsedCap)
    }

    func test_visible_showAll_returnsEverything() {
        let all = fixture(orphans: 2, live: 14)
        XCTAssertEqual(AgentProcessListModel.visible(all, showAll: true), all)
    }

    func test_hiddenCount_countsEverythingBeyondCap() {
        let all = fixture(orphans: 2, live: 14)
        XCTAssertEqual(AgentProcessListModel.hiddenCount(all, showAll: false), 11)
        XCTAssertEqual(AgentProcessListModel.hiddenCount(all, showAll: true), 0)
    }

    func test_hiddenCount_zeroWhenUnderCap() {
        let all = fixture(orphans: 0, live: 5)
        XCTAssertEqual(AgentProcessListModel.hiddenCount(all, showAll: false), 0)
    }

    // MARK: - AgentProcessRowFormat.runningText

    func test_runningText_minutesSeconds() {
        XCTAssertEqual(AgentProcessRowFormat.runningText(etime: "05:30"), "Running 5m")
    }

    func test_runningText_hoursMinutesSeconds() {
        XCTAssertEqual(AgentProcessRowFormat.runningText(etime: "02:13:45"), "Running 2h 13m")
    }

    func test_runningText_daysForm() {
        XCTAssertEqual(AgentProcessRowFormat.runningText(etime: "1-03:00:00"), "Running 1d 3h")
    }

    func test_runningText_dropsZeroSecondaryComponent() {
        XCTAssertEqual(AgentProcessRowFormat.runningText(etime: "2-00:10:00"), "Running 2d")
        XCTAssertEqual(AgentProcessRowFormat.runningText(etime: "01:00:59"), "Running 1h")
    }

    func test_runningText_underAMinute() {
        XCTAssertEqual(AgentProcessRowFormat.runningText(etime: "00:45"), "Just started")
    }

    func test_runningText_unparseable_passesThrough() {
        // Surprise ps format degrades to the old raw display, not garbage.
        XCTAssertEqual(AgentProcessRowFormat.runningText(etime: "weird"), "weird")
        XCTAssertEqual(AgentProcessRowFormat.runningText(etime: ""), "")
        XCTAssertEqual(AgentProcessRowFormat.runningText(etime: "x-01:00:00"), "x-01:00:00")
        XCTAssertEqual(AgentProcessRowFormat.runningText(etime: "01:02:03:04"), "01:02:03:04")
    }

    // MARK: - AgentProcessRowFormat.activityText

    func test_activityText_tierBoundaries() {
        XCTAssertEqual(AgentProcessRowFormat.activityText(cpuPercent: 0.0), "idle")
        XCTAssertEqual(AgentProcessRowFormat.activityText(cpuPercent: 1.9), "idle")
        XCTAssertEqual(AgentProcessRowFormat.activityText(cpuPercent: 2.0), "active")
        XCTAssertEqual(AgentProcessRowFormat.activityText(cpuPercent: 29.9), "active")
        XCTAssertEqual(AgentProcessRowFormat.activityText(cpuPercent: 30.0), "busy")
        XCTAssertEqual(AgentProcessRowFormat.activityText(cpuPercent: 312.5), "busy")
    }

    func test_visible_allOrphans_stillCapped_toggleAppears() {
        // Regression guard: when a parent editor quits, EVERY session
        // reparents to launchd at once (11 real claude rows observed). An
        // uncapped all-orphans list re-creates the popover crop this model
        // exists to prevent — cap applies regardless of orphan status, and
        // hiddenCount > 0 guarantees the Show-all toggle appears.
        let all = fixture(orphans: 11, live: 0)
        let visible = AgentProcessListModel.visible(all, showAll: false)
        XCTAssertEqual(visible.count, AgentProcessListModel.collapsedCap)
        XCTAssertEqual(AgentProcessListModel.hiddenCount(all, showAll: false), 6)
    }
}
