import AppKit
import XCTest
@testable import MenuBar

final class PopoverAnchorTests: XCTestCase {
    func testDetachedStatusButtonCannotPresentPopover() {
        let detached = NSRect(x: 0, y: -22, width: 38, height: 22)
        XCTAssertFalse(MenuBarController.hasVisibleAnchor(detached, on: nil))
        XCTAssertFalse(MenuBarController.hasVisibleAnchor(detached, on: NSRect(x: 0, y: 0, width: 1440, height: 900)))
    }

    func testVisibleStatusButtonOnEitherScreenCanPresentPopover() {
        XCTAssertTrue(MenuBarController.hasVisibleAnchor(
            NSRect(x: 1200, y: 878, width: 22, height: 22),
            on: NSRect(x: 0, y: 0, width: 1440, height: 900)))
        XCTAssertTrue(MenuBarController.hasVisibleAnchor(
            NSRect(x: -300, y: 1058, width: 22, height: 22),
            on: NSRect(x: -1920, y: 0, width: 1920, height: 1080)))
        XCTAssertFalse(MenuBarController.hasVisibleAnchor(
            .zero, on: NSRect(x: 0, y: 0, width: 1440, height: 900)))
    }
}
