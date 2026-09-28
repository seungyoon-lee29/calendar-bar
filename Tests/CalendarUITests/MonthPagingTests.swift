import XCTest
@testable import CalendarUI

final class MonthPagingTests: XCTestCase {
    func testTracksPointerWithoutChangingPageAndClampsToOnePage() {
        var paging = MonthPagingState()
        paging.drag(x: -24, y: 3, width: 340)
        XCTAssertEqual(paging.offset, -24)
        XCTAssertFalse(paging.isSettling)
        paging.drag(x: -90, y: 4, width: 340)
        XCTAssertEqual(paging.offset, -90)
        paging.drag(x: -900, y: 4, width: 340)
        XCTAssertEqual(paging.offset, -340)
        paging.drag(x: 15, y: 60, width: 340)
        XCTAssertEqual(paging.offset, 0)
    }

    func testSettlementLocksInputAndCompletesExactlyOnce() {
        var paging = MonthPagingState()
        paging.drag(x: -80, y: 0, width: 340)
        let token = paging.settle(direction: 1, width: 340)!
        XCTAssertEqual(paging.offset, -340)
        XCTAssertTrue(paging.isSettling)
        paging.drag(x: 100, y: 0, width: 340)
        XCTAssertEqual(paging.offset, -340)
        XCTAssertNil(paging.settle(direction: -1, width: 340))
        XCTAssertTrue(paging.finish(token))
        XCTAssertEqual(paging.offset, 0)
        XCTAssertFalse(paging.finish(token))
    }

    func testShortDragReturnsAndResetInvalidatesOldAnimation() {
        var paging = MonthPagingState()
        paging.drag(x: 25, y: 0, width: 340)
        let token = paging.settle(direction: nil, width: 340)!
        XCTAssertEqual(paging.offset, 0)
        XCTAssertTrue(paging.finish(token))
        let stale = paging.settle(direction: -1, width: 340)!
        paging.reset()
        let next = paging.settle(direction: 1, width: 340)!
        XCTAssertFalse(paging.finish(stale))
        XCTAssertTrue(paging.isSettling)
        XCTAssertTrue(paging.finish(next))
    }
}
