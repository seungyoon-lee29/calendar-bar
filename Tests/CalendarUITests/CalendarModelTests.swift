import XCTest
import CalendarCore
import CalendarAccess
@testable import CalendarUI

final class CalendarModelTests: XCTestCase {
    func testDragThresholdAndAxis() {
        XCTAssertEqual(MonthSwipe.direction(x: -41, y: 4), 1)
        XCTAssertEqual(MonthSwipe.direction(x: 45, y: 2), -1)
        for (x, y) in [(40.0, 0.0), (-39, 0), (60, 60), (45, 90), (0, 0)] {
            XCTAssertNil(MonthSwipe.direction(x: x, y: y))
        }
    }
    @MainActor func testSelectionMonthClampAndOpenReset() async {
        let model = CalendarModel(access: CalendarAccessController(backend: EmptyBackend(), storage: MemorySelection(), observeChanges: false), now: date("2026-01-31"), timeZone: TimeZone(secondsFromGMT: 0)!)
        model.moveMonth(1)
        XCTAssertEqual(model.formatted(model.calendar.selectedDate, "yyyy-MM-dd"), "2026-02-28")
        model.select(date("2026-03-02"))
        XCTAssertEqual(model.formatted(model.calendar.displayedMonth, "yyyy-MM"), "2026-03")
        model.dateChanged(date("2026-04-05"), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(model.formatted(model.calendar.displayedMonth, "yyyy-MM"), "2026-03")
        model.open(now: date("2026-04-05"), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(model.formatted(model.calendar.selectedDate, "yyyy-MM-dd"), "2026-04-05")
        await model.waitForRefresh()
        XCTAssertEqual(model.access.state, .connectionRequired)
    }
    @MainActor func testRapidNavigationQueriesLatestGridAndFormatsSpanningEvents() async {
        let backend = RecordingBackend()
        let access = CalendarAccessController(backend: backend, storage: SelectedCalendar(), observeChanges: false)
        let model = CalendarModel(access: access, now: date("2026-09-28"), timeZone: TimeZone(secondsFromGMT: 0)!)
        model.moveMonth(1)
        model.moveMonth(1)
        model.select(date("2026-12-03"))
        await model.waitForRefresh()
        let intervals = await backend.intervals
        XCTAssertEqual(intervals.last, model.calendar.grid.queryInterval)
        XCTAssertEqual(access.state, .loaded)
        let color = RGBAColor(red: 0, green: 0, blue: 1)
        let event = EventOccurrence(calendarID: "c", calendarName: "", color: color, eventID: "e", title: "", start: date("2026-12-02"), end: date("2026-12-04"), isAllDay: false)
        XCTAssertEqual(model.timeLabel(event), "진행 중")
        let allDay = EventOccurrence(calendarID: "c", calendarName: "", color: color, eventID: "a", title: "", start: date("2026-12-02"), end: date("2026-12-04"), isAllDay: true)
        XCTAssertEqual(model.timeLabel(allDay), "종일")
    }
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value + "T00:00:00Z")! }
}
private actor EmptyBackend: CalendarBackend {
    func permission() async -> CalendarPermission { .unknown }
    func requestAccess() async throws { XCTFail("Must not request access automatically") }
    func calendars() async throws -> [CalendarDescriptor] { [] }
    func events(interval: DateInterval, calendarIDs: Set<String>) async throws -> [EventOccurrence] { [] }
}
@MainActor private final class MemorySelection: CalendarSelectionStorage {
    func load() -> Set<String> { [] }
    func save(_ ids: Set<String>) {}
}

private actor RecordingBackend: CalendarBackend {
    var intervals: [DateInterval] = []
    func permission() async -> CalendarPermission { .authorized }
    func requestAccess() async throws { XCTFail("Must not request access automatically") }
    func calendars() async throws -> [CalendarDescriptor] {
        [CalendarDescriptor(id: "c", name: "Test", sourceName: "Test", color: RGBAColor(red: 0, green: 0, blue: 1))]
    }
    func events(interval: DateInterval, calendarIDs: Set<String>) async throws -> [EventOccurrence] { intervals.append(interval); return [] }
}
@MainActor private final class SelectedCalendar: CalendarSelectionStorage {
    func load() -> Set<String> { ["c"] }
    func save(_ ids: Set<String>) {}
}
