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

    func test_visible_overCap_capsLiveRowsOnly() {
        let all = fixture(orphans: 2, live: 14)
        let visible = AgentProcessListModel.visible(all, showAll: false)
        XCTAssertEqual(visible.filter(\.isOrphan).count, 2, "orphans are never hidden")
        XCTAssertEqual(visible.filter { !$0.isOrphan }.count, AgentProcessListModel.liveCap)
        // Order preserved: orphans first, then the first capped live rows.
        XCTAssertEqual(visible.map(\.pid), [100, 101, 200, 201, 202, 203, 204])
    }

    func test_visible_showAll_returnsEverything() {
        let all = fixture(orphans: 2, live: 14)
        XCTAssertEqual(AgentProcessListModel.visible(all, showAll: true), all)
    }

    func test_hiddenCount_countsOnlyLiveBeyondCap() {
        let all = fixture(orphans: 2, live: 14)
        XCTAssertEqual(AgentProcessListModel.hiddenCount(all, showAll: false), 9)
        XCTAssertEqual(AgentProcessListModel.hiddenCount(all, showAll: true), 0)
    }

    func test_hiddenCount_zeroWhenUnderCap() {
        let all = fixture(orphans: 0, live: 5)
        XCTAssertEqual(AgentProcessListModel.hiddenCount(all, showAll: false), 0)
    }

    func test_visible_manyOrphans_allShownEvenBeyondCap() {
        // Orphans are the actionable rows; the cap must never swallow them.
        let all = fixture(orphans: 8, live: 2)
        let visible = AgentProcessListModel.visible(all, showAll: false)
        XCTAssertEqual(visible.filter(\.isOrphan).count, 8)
    }
}
