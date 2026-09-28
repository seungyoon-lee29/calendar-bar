import XCTest
@testable import CalendarCore

final class CalendarCoreTests: XCTestCase {
    let utc = CalendarContext(timeZone: TimeZone(secondsFromGMT: 0)!)
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func testGridSundayFirstFullWeeksAndQueryBounds() {
        let five = utc.monthGrid(containing: date("2024-02-15T12:00:00Z"))
        XCTAssertEqual(five.days.count, 35)
        XCTAssertEqual(five.days.first, date("2024-01-28T00:00:00Z"))
        XCTAssertEqual(five.days.last, date("2024-03-02T00:00:00Z"))
        XCTAssertEqual(five.queryInterval.end, date("2024-03-03T00:00:00Z"))
        XCTAssertEqual(utc.monthGrid(containing: date("2024-03-15T12:00:00Z")).days.count, 42)
        XCTAssertEqual(utc.monthGrid(containing: date("2026-02-15T12:00:00Z")).days.count, 28)
    }
    func testNavigationClampsAndCrossesYear() {
        var state = CalendarState(now: date("2023-01-31T12:00:00Z"), timeZone: utc.calendar.timeZone)
        state.moveMonth(by: 1)
        XCTAssertEqual(state.selectedDate, date("2023-02-28T00:00:00Z"))
        state.moveMonth(by: 1)
        XCTAssertEqual(state.selectedDate, date("2023-03-28T00:00:00Z"))
        state.moveMonth(by: -3)
        XCTAssertEqual(state.selectedDate, date("2022-12-28T00:00:00Z"))
        state.open(at: date("2024-01-31T12:00:00Z"))
        state.moveMonth(by: 1)
        XCTAssertEqual(state.selectedDate, date("2024-02-29T00:00:00Z"))
    }
    func testSpilloverAndTodayRefreshPreserveBrowsingUntilOpen() {
        var state = CalendarState(now: date("2024-01-31T12:00:00Z"), timeZone: utc.calendar.timeZone)
        state.select(date("2024-02-02T12:00:00Z"))
        XCTAssertEqual(state.displayedMonth, date("2024-02-01T00:00:00Z"))
        state.refreshToday(at: date("2024-04-01T00:00:00Z"))
        XCTAssertEqual(state.today, date("2024-04-01T00:00:00Z"))
        XCTAssertEqual(state.selectedDate, date("2024-02-02T00:00:00Z"))
        state.refreshToday(at: date("2024-04-01T00:00:00Z"), timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertEqual(state.context.calendar.component(.day, from: state.selectedDate), 2)
        XCTAssertEqual(state.context.calendar.component(.month, from: state.displayedMonth), 2)
        XCTAssertEqual(state.context.calendar.component(.day, from: state.today), 31)
        state.open(at: date("2024-05-20T12:00:00Z"))
        XCTAssertEqual(state.selectedDate, state.today)
        XCTAssertEqual(state.context.calendar.component(.month, from: state.displayedMonth), 5)
    }
    func testDSTGridUsesCalendarDays() {
        let la = CalendarContext(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        let grid = la.monthGrid(containing: date("2024-03-10T12:00:00Z"))
        XCTAssertEqual(Set(grid.days.map { la.calendar.component(.hour, from: $0) }), [0])
        let index = grid.days.firstIndex(of: date("2024-03-10T08:00:00Z"))!
        XCTAssertEqual(grid.days[index + 1].timeIntervalSince(grid.days[index]), 23 * 3600)
        let fall = la.monthGrid(containing: date("2024-11-03T12:00:00Z"))
        let fallIndex = fall.days.firstIndex(of: date("2024-11-03T07:00:00Z"))!
        XCTAssertEqual(fall.days[fallIndex + 1].timeIntervalSince(fall.days[fallIndex]), 25 * 3600)
    }
    func event(_ id: String, start: String, end: String, allDay: Bool = false, title: String? = "Meeting", calendar: String = "one") -> EventOccurrence {
        EventOccurrence(calendarID: calendar, calendarName: calendar, color: RGBAColor(red: 1, green: 0, blue: 0), eventID: id, title: title, start: date(start), end: date(end), isAllDay: allDay)
    }
    func testHalfOpenSpanningAndZeroDurationEvents() {
        let spanning = event("span", start: "2024-03-01T23:00:00Z", end: "2024-03-03T00:00:00Z")
        let zero = event("zero", start: "2024-03-02T00:00:00Z", end: "2024-03-02T00:00:00Z")
        let events = [spanning, zero]
        XCTAssertEqual(EventIndex.events(on: date("2024-03-01T12:00:00Z"), in: events, context: utc).count, 1)
        XCTAssertEqual(EventIndex.events(on: date("2024-03-02T12:00:00Z"), in: events, context: utc).count, 2)
        XCTAssertTrue(EventIndex.events(on: date("2024-03-03T12:00:00Z"), in: events, context: utc).isEmpty)
    }
    func testEventsAtDSTLocalMidnight() {
        let la = CalendarContext(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        let allDay = event("dst", start: "2024-03-10T08:00:00Z", end: "2024-03-11T07:00:00Z", allDay: true)
        let nextDay = event("next", start: "2024-03-11T07:00:00Z", end: "2024-03-11T07:00:00Z")
        XCTAssertEqual(EventIndex.events(on: date("2024-03-10T20:00:00Z"), in: [allDay, nextDay], context: la).map(\.eventID), ["dst"])
        XCTAssertEqual(EventIndex.events(on: date("2024-03-11T20:00:00Z"), in: [allDay, nextDay], context: la).map(\.eventID), ["next"])
    }
    func testSortIdentityFallbackAndUniqueCalendarDots() {
        let a = event("a", start: "2024-03-02T10:00:00Z", end: "2024-03-02T11:00:00Z", title: "B")
        let b = event("b", start: "2024-03-02T10:00:00Z", end: "2024-03-02T11:00:00Z", title: "A")
        let c = event("c", start: "2024-03-02T12:00:00Z", end: "2024-03-03T00:00:00Z", allDay: true, title: nil, calendar: "two")
        let earlier = event("early", start: "2024-03-02T09:00:00Z", end: "2024-03-02T10:00:00Z")
        let recurrence = event("a", start: "2024-03-03T10:00:00Z", end: "2024-03-03T11:00:00Z")
        XCTAssertNotEqual(a.id, recurrence.id)
        XCTAssertNotEqual(a.id, event("a", start: "2024-03-02T10:00:00Z", end: "2024-03-02T11:00:00Z", calendar: "two").id)
        XCTAssertEqual(c.title, "제목 없음")
        XCTAssertEqual(EventIndex.events(on: a.start, in: [a, b, c, earlier], context: utc).map(\.eventID), ["c", "early", "b", "a"])
        XCTAssertEqual(EventIndex.colors(on: a.start, in: [a, b, c], context: utc).count, 2)
        let tied = event("z", start: "2024-03-02T10:00:00Z", end: "2024-03-02T11:00:00Z", title: "B")
        XCTAssertEqual(EventIndex.events(on: a.start, in: [tied, a], context: utc).map(\.eventID), ["a", "z"])
    }
}
