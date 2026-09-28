import AppKit
import XCTest
@testable import MenuBar

final class PopoverAnchorTests: XCTestCase {
    @MainActor func testColdPresentationWaitsForAnchorAndActivation() async {
        var active = false
        var anchorReady = false
        var ticks = 0
        let presentation = PopoverPresentation(wait: {
            ticks += 1
            if ticks == 1 { active = true }
            if ticks == 2 { anchorReady = true }
            await Task.yield()
        })
        var shown = false
        presentation.request(activate: {}, attempt: {
            guard active && anchorReady else { return false }
            shown = true
            return true
        })
        XCTAssertFalse(shown)
        await presentation.waitUntilIdle()
        XCTAssertTrue(shown, "Notification click must survive cold status-item and activation readiness")
    }

    @MainActor func testUnavailableAnchorRetriesAreBoundedAndCloseCancelsPendingShow() async {
        let presentation = PopoverPresentation(maximumAttempts: 4, wait: { await Task.yield() })
        var attempts = 0
        presentation.request(activate: {}, attempt: { attempts += 1; return false })
        await presentation.waitUntilIdle()
        XCTAssertEqual(attempts, 4)
        presentation.request(activate: {}, attempt: { attempts += 1; return false })
        presentation.cancel()
        await Task.yield()
        XCTAssertEqual(attempts, 5)
    }

    @MainActor func testNewRequestCancelsOldPendingPresentation() async {
        let presentation = PopoverPresentation(wait: { await Task.yield() })
        var oldAttempts = 0
        var newAttempts = 0
        presentation.request(activate: {}, attempt: { oldAttempts += 1; return false })
        presentation.request(activate: {}, attempt: { newAttempts += 1; return true })
        await Task.yield()
        XCTAssertEqual(oldAttempts, 1)
        XCTAssertEqual(newAttempts, 1)
    }

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
