import XCTest
import CalendarCore
import CalendarAccess
@testable import CalendarUI

final class SearchAgendaTests: XCTestCase {
    func testMultidayAgendaRowsHaveStableDistinctPresentationIdentities() {
        let context = CalendarContext(timeZone: TimeZone(secondsFromGMT: 0)!)
        let event = EventOccurrence(calendarID: "qa", calendarName: "Synthetic", color: .init(red: 0, green: 0, blue: 1), eventID: "multi", title: "Synthetic", start: day("2026-09-27"), end: day("2026-09-30"), isAllDay: true)
        let interval = DateInterval(start: day("2026-09-28"), end: day("2026-09-30"))
        let groups = AgendaIndex.groups(events: [event], interval: interval, context: context)
        let rows = groups.flatMap { group in group.events.map { AgendaDisplayRow(day: group.day, event: $0) } }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.event.id), [event.id, event.id])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2, "The same occurrence must remain visible on both days in a flattened lazy stack")
        let refreshed = AgendaIndex.groups(events: [event], interval: interval, context: context).flatMap { group in group.events.map { AgendaDisplayRow(day: group.day, event: $0) } }
        XCTAssertEqual(rows.map(\.id), refreshed.map(\.id))
    }

    @MainActor func testRangeNavigationAndOpenReset() async {
        let model = CalendarModel(access: CalendarAccessController(backend: SearchBackend(), storage: SearchSelection(), observeChanges: false), now: day("2026-09-28"), timeZone: TimeZone(secondsFromGMT: 0)!)
        model.setTab(.upcoming)
        let end = model.agendaInterval.end
        model.loadMoreAgenda()
        XCTAssertEqual(model.agendaInterval.end.timeIntervalSince(end), 30 * 86400)
        model.searchStart = day("2026-10-01")
        model.searchEnd = day("2026-09-01")
        model.searchText = "test"
        await model.waitForSearch()
        XCTAssertNil(model.searchInterval)
        let token = model.presentationID
        model.select(day("2026-10-01"))
        XCTAssertNotEqual(token, model.presentationID)
        model.open(now: day("2026-09-28"), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(model.tab, .calendar)
        XCTAssertEqual(model.searchText, "")
        XCTAssertEqual(model.agendaInterval.end, end)
        await model.waitForRefresh()
    }
    @MainActor func testSearchAndResolvedNavigation() async {
        let backend = SearchBackend()
        let model = CalendarModel(access: CalendarAccessController(backend: backend, storage: SearchSelection(), observeChanges: false), now: day("2026-09-28"), timeZone: TimeZone(secondsFromGMT: 0)!)
        model.searchText = "ignored"
        model.searchText = " TEST "
        await model.waitForSearch()
        XCTAssertEqual(model.searchResults.count, 1)
        let event = model.searchResults[0]
        await model.activate(event, interval: model.searchInterval)
        XCTAssertEqual(model.calendar.selectedDate, day("2026-10-03"))
        XCTAssertEqual(model.highlightedEventID, event.id)
        XCTAssertEqual(model.searchText, "")
        model.searchText = "test"
        await model.waitForSearch()
        await backend.setMissing()
        await model.activate(event, interval: model.searchInterval)
        XCTAssertNotNil(model.navigationMessage)
        XCTAssertEqual(model.searchText, "test")
        await model.waitForRefresh()
    }
    @MainActor func testChannelStatesAndSearchClearPreservesTab() async {
        let backend = SearchBackend()
        let access = CalendarAccessController(backend: backend, storage: SearchSelection(), observeChanges: false)
        let model = CalendarModel(access: access, now: day("2026-09-28"), timeZone: TimeZone(secondsFromGMT: 0)!)
        model.setTab(.upcoming)
        await model.waitForAgenda()
        XCTAssertEqual(model.agendaState, .loaded)
        XCTAssertEqual(model.agendaGroups.count, 1)
        model.searchText = "unmatched"
        await model.waitForSearch()
        XCTAssertEqual(model.searchState, .loaded)
        XCTAssertTrue(model.searchResults.isEmpty)
        model.searchText = ""
        XCTAssertEqual(model.tab, .upcoming)
        await backend.setFailure(true)
        model.refreshAgenda()
        await model.waitForAgenda()
        XCTAssertEqual(model.agendaState, .failed)
        await backend.setFailure(false)
        model.refreshAgenda()
        await model.waitForAgenda()
        XCTAssertEqual(model.agendaState, .loaded)
        await access.setSelectedCalendarIDs([])
        XCTAssertEqual(model.agendaState, .selectionRequired)
        await backend.setPermission(.denied)
        model.refreshAgenda()
        await model.waitForAgenda()
        XCTAssertEqual(model.agendaState, .connectionRequired)
        XCTAssertTrue(model.agendaGroups.isEmpty)
    }
    @MainActor func testChangingRangeWhileSearchInFlightHidesOldResults() async {
        let backend = SearchBackend()
        await backend.setDelay(true)
        let model = CalendarModel(access: CalendarAccessController(backend: backend, storage: SearchSelection(), observeChanges: false), now: day("2026-09-28"), timeZone: TimeZone(secondsFromGMT: 0)!)
        model.searchText = "test"
        try? await Task.sleep(for: .milliseconds(300))
        let oldPresentation = model.presentationID
        model.searchStart = day("2026-11-01")
        model.searchEnd = day("2026-11-30")
        XCTAssertNotEqual(oldPresentation, model.presentationID)
        XCTAssertTrue(model.searchResults.isEmpty)
        await model.waitForSearch()
        XCTAssertEqual(model.searchState, .loaded)
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertEqual(model.access.snapshot(for: .search).interval, model.searchInterval)
    }

}
private func day(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "T00:00:00Z")! }
private actor SearchBackend: CalendarBackend {
    var missing = false
    var access: CalendarPermission = .authorized
    var fail = false
    var delayed = false
    func setDelay(_ value: Bool) { delayed = value }
    func setPermission(_ value: CalendarPermission) { access = value }
    func setFailure(_ value: Bool) { fail = value }
    func setMissing() { missing = true }
    func permission() async -> CalendarPermission { access }
    func requestAccess() async throws {}
    func calendars() async throws -> [CalendarDescriptor] { [.init(id: "c", name: "Synthetic", sourceName: "Synthetic", color: .init(red: 0, green: 0, blue: 1))] }
    func events(interval: DateInterval, calendarIDs: Set<String>) async throws -> [EventOccurrence] {
        if delayed { try? await Task.sleep(for: .milliseconds(350)) }
        if fail { throw CalendarQueryError.invalidRange }
        return [event]
    }
    var event: EventOccurrence { .init(calendarID: "c", calendarName: "Synthetic", color: .init(red: 0, green: 0, blue: 1), eventID: "e", title: "Test", start: day("2026-10-03"), end: day("2026-10-04"), isAllDay: true) }
    func resolve(identity: ReminderIdentity, anchor: OccurrenceAnchor?, isRecurring: Bool, searchInterval: DateInterval?, calendarIDs: Set<String>) async throws -> CalendarEventResolution { missing ? .missing : .found(event) }
}
@MainActor private final class SearchSelection: CalendarSelectionStorage {
    func load() -> Set<String> { ["c"] }
    func save(_ ids: Set<String>) {}
}
