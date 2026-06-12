//
//  ZeroSizeChildSpacingTests.swift
//  KwotaTests
//
//  Pins the SwiftUI spacing semantics behind the Usage-tab phantom-gap fix
//  (UsageTabView wraps its banner TimelineView in a spacing-0 VStack):
//  a permanent stack child that resolves to zero size — a TimelineView
//  whose content builder produced nothing — still earns a spacing slot in
//  a spacing-N VStack, and a modifier applied OUTSIDE a resolved-empty
//  @ViewBuilder result materializes the same phantom height. If either
//  behavior changes in a future SwiftUI, these assertions flag that the
//  workaround (and its in-branch .padding placement) can be revisited.
//

import XCTest
import SwiftUI
@testable import Kwota

@MainActor
final class ZeroSizeChildSpacingTests: XCTestCase {
    private func fittingHeight<V: View>(_ v: V) -> CGFloat {
        NSHostingView(rootView: v).fittingSize.height
    }

    @ViewBuilder
    private func conditionalContent(_ show: Bool) -> some View {
        if show { Color.blue.frame(height: 30) }
    }

    func test_emptyTimelineView_earnsSpacingSlotInVStack() {
        let base = fittingHeight(
            VStack(spacing: 10) {
                Color.red.frame(width: 50, height: 50)
            }
        )
        let withEmptyTimeline = fittingHeight(
            VStack(spacing: 10) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    self.conditionalContent(false)
                }
                Color.red.frame(width: 50, height: 50)
            }
        )
        XCTAssertEqual(base, 50, accuracy: 0.5)
        XCTAssertEqual(withEmptyTimeline, base + 10, accuracy: 0.5,
                       "zero-size TimelineView still earns one spacing slot — the Usage-tab phantom gap")
    }

    func test_spacingZeroWrapper_withInBranchPadding_fixesBothStates() {
        // No banner: wrapper contributes nothing extra.
        let hidden = fittingHeight(
            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    self.conditionalContent(false)
                }
                Color.red.frame(width: 50, height: 50)
            }
        )
        // Banner showing, padding INSIDE the branch: 30 + 10 + 50.
        let showing = fittingHeight(
            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    self.conditionalContent(true)
                        .padding(.bottom, 10)
                }
                Color.red.frame(width: 50, height: 50)
            }
        )
        XCTAssertEqual(hidden, 50, accuracy: 0.5)
        XCTAssertEqual(showing, 90, accuracy: 0.5)
    }

    func test_paddingOutsideResolvedEmptyContent_materializes() {
        // The trap that rules out `statusBanner(now:).padding(.bottom, 10)`:
        // padding around nothing still renders 10pt.
        let h = fittingHeight(
            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    self.conditionalContent(false)
                        .padding(.bottom, 10)
                }
                Color.red.frame(width: 50, height: 50)
            }
        )
        XCTAssertEqual(h, 60, accuracy: 0.5,
                       "padding on resolved-empty builder output materializes — keep banner padding in-branch")
    }
}
