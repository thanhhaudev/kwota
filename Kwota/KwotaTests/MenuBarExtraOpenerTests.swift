import XCTest
import AppKit
@testable import Kwota

@MainActor
final class MenuBarExtraOpenerTests: XCTestCase {
    func test_findStatusItemButton_returns_nil_for_empty_list() {
        XCTAssertNil(MenuBarExtraOpener.findStatusItemButton(in: []))
    }

    func test_findStatusItemButton_returns_nil_when_no_match() {
        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: .borderless, backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        defer { plain.close() }
        XCTAssertNil(MenuBarExtraOpener.findStatusItemButton(in: [plain]))
    }

    func test_findStatusItemButton_finds_status_bar_button_in_subviews() {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        defer { host.close() }
        let button = NSStatusBarButton()
        host.contentView?.addSubview(button)
        host.title = "MenuBarExtraStatusItemWindow"

        let found = MenuBarExtraOpener.findStatusItemButton(in: [host])
        XCTAssertNotNil(found)
    }

    func test_isPopupVisible_returns_value_from_matched_window() {
        let visible = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                               styleMask: .borderless, backing: .buffered, defer: false)
        visible.isReleasedWhenClosed = false
        defer { visible.close() }
        visible.contentView?.addSubview(NSStatusBarButton())
        visible.title = "MenuBarExtraPanel"

        visible.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        visible.orderFront(nil)
        XCTAssertTrue(MenuBarExtraOpener.isPopupVisible(in: [visible]))

        visible.orderOut(nil)
        XCTAssertFalse(MenuBarExtraOpener.isPopupVisible(in: [visible]))
    }
}
