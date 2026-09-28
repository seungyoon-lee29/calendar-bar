import XCTest
@testable import MenuBar

final class StatusDateTests: XCTestCase {
    func testGregorianDayUsesSuppliedTimezone() {
        let date = ISO8601DateFormatter().date(from: "2026-09-28T23:30:00Z")!
        XCTAssertEqual(StatusDate.day(at: date, timeZone: TimeZone(secondsFromGMT: 0)!), 28)
        XCTAssertEqual(StatusDate.day(at: date, timeZone: TimeZone(secondsFromGMT: 9 * 3600)!), 29)
    }
    func testNextMidnightAfterDayStartingAtOneResetsToMidnight() {
        let zone = TimeZone(identifier: "America/Asuncion")!
        let noon = ISO8601DateFormatter().date(from: "2023-10-01T15:00:00Z")!
        let expected = ISO8601DateFormatter().date(from: "2023-10-02T03:00:00Z")!
        XCTAssertEqual(StatusDate.nextMidnight(after: noon, timeZone: zone), expected)
    }
    func testNextMidnightAcrossDaylightSavingIsCalendarBased() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let start = ISO8601DateFormatter().date(from: "2026-03-08T08:00:00Z")!
        let next = StatusDate.nextMidnight(after: start, timeZone: zone)
        XCTAssertEqual(next.timeIntervalSince(start), 23 * 3600)
        XCTAssertEqual(StatusDate.day(at: next, timeZone: zone), 9)
    }
}
