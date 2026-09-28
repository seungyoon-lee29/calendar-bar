import XCTest
@testable import CalendarAccess
import CalendarCore

@MainActor final class CalendarAccessTests: XCTestCase {
    let interval = DateInterval(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
    func testStatesAndPersistence() async {
        let backend = FakeBackend()
        let storage = MemorySelection()
        let controller = CalendarAccessController(backend: backend, storage: storage, observeChanges: false)
        await controller.refresh(interval: interval)
        XCTAssertEqual(controller.state, .connectionRequired)
        backend.permissionValue = .authorized
        await controller.refresh(interval: interval)
        XCTAssertEqual(controller.state, .noCalendars)
        backend.descriptors = [descriptor("a"), descriptor("b")]
        await controller.refresh(interval: interval)
        XCTAssertEqual(controller.state, .selectionRequired)
        await controller.setSelectedCalendarIDs(["b", "missing"])
        XCTAssertEqual(controller.state, .loaded)
        XCTAssertEqual(controller.effectiveSelectedCalendarIDs, ["b"])
        XCTAssertEqual(storage.ids, ["b", "missing"])
        XCTAssertEqual(backend.queries.last?.1, ["b"])
        XCTAssertTrue(controller.events.isEmpty)
        backend.descriptors = [descriptor("a")]
        await controller.refresh(interval: interval)
        XCTAssertEqual(controller.state, .selectionRequired)
        XCTAssertTrue(controller.effectiveSelectedCalendarIDs.isEmpty)
    }
    func testLatestQueryWinsAndRevocationClearsData() async {
        let backend = FakeBackend()
        backend.permissionValue = .authorized
        backend.descriptors = [descriptor("a")]
        backend.suspendQueries = true
        let controller = CalendarAccessController(backend: backend, storage: MemorySelection(["a"]), observeChanges: false)
        let old = Task { await controller.refresh(interval: interval) }
        await waitFor { backend.pending.count == 1 }
        let nextInterval = DateInterval(start: interval.end, duration: 100)
        let latest = Task { await controller.refresh(interval: nextInterval) }
        await waitFor { backend.pending.count == 2 }
        backend.pending[1].resume(returning: [event("new", at: 210)])
        await latest.value
        backend.pending[0].resume(returning: [event("old", at: 110)])
        await old.value
        XCTAssertEqual(controller.events.map(\.eventID), ["new"])
        let revoked = Task { await controller.refresh(interval: interval) }
        await waitFor { backend.pending.count == 3 }
        backend.permissionValue = .denied
        backend.pending[2].resume(returning: [event("secret", at: 110)])
        await revoked.value
        XCTAssertEqual(controller.state, .connectionRequired)
        XCTAssertTrue(controller.events.isEmpty)
        XCTAssertTrue(controller.calendars.isEmpty)
    }
    func testFailureAndHalfOpenFilteringAndDistinctOccurrences() async {
        let backend = FakeBackend()
        backend.permissionValue = .authorized
        backend.descriptors = [descriptor("a")]
        backend.results = [event("repeat", at: 110), event("repeat", at: 120), event("edge", at: 200), event("wrong", at: 110, calendarID: "b")]
        let controller = CalendarAccessController(backend: backend, storage: MemorySelection(["a"]), observeChanges: false)
        await controller.refresh(interval: interval)
        XCTAssertEqual(controller.events.count, 2)
        XCTAssertNotEqual(controller.events[0].id, controller.events[1].id)
        backend.fail = true
        await controller.refresh(interval: interval)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(controller.events.isEmpty)
    }
    func testDeniedRequestAndPermissionRequestDoesNotOverwriteNewRange() async {
        let backend = FakeBackend()
        let controller = CalendarAccessController(backend: backend, storage: MemorySelection(["a"]), observeChanges: false)
        await controller.refresh(interval: interval)
        backend.permissionValue = .denied
        await controller.requestAccess()
        XCTAssertEqual(controller.permission, .denied)
        XCTAssertEqual(controller.state, .connectionRequired)
        backend.permissionValue = .authorized
        backend.descriptors = [descriptor("a")]
        backend.suspendRequest = true
        let request = Task { await controller.requestAccess() }
        await waitFor { backend.requestContinuation != nil }
        let latest = DateInterval(start: interval.end, duration: 100)
        await controller.refresh(interval: latest)
        backend.requestContinuation?.resume()
        await request.value
        XCTAssertEqual(backend.queries.last?.0, latest)
    }
    func testSelectionChangeRejectsOldResults() async {
        let backend = FakeBackend()
        backend.permissionValue = .authorized
        backend.descriptors = [descriptor("a"), descriptor("b")]
        backend.suspendQueries = true
        let controller = CalendarAccessController(backend: backend, storage: MemorySelection(["a"]), observeChanges: false)
        let old = Task { await controller.refresh(interval: interval) }
        await waitFor { backend.pending.count == 1 }
        let change = Task { await controller.setSelectedCalendarIDs(["b"]) }
        await waitFor { backend.pending.count == 2 }
        backend.pending[1].resume(returning: [event("new", at: 110, calendarID: "b")])
        await change.value
        backend.pending[0].resume(returning: [event("old", at: 110)])
        await old.value
        XCTAssertEqual(controller.events.map(\.calendarID), ["b"])
        XCTAssertEqual(controller.calendars.map(\.sourceName), ["a", "b"])
    }
    func testOverlapBoundaries() {
        func occurrence(_ start: Double, _ end: Double) -> EventOccurrence {
            EventOccurrence(calendarID: "a", calendarName: "a", color: .init(red: 0, green: 0, blue: 0), eventID: "id", title: nil, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end), isAllDay: true)
        }
        XCTAssertFalse(CalendarAccessController.overlaps(occurrence(50, 100), interval))
        XCTAssertFalse(CalendarAccessController.overlaps(occurrence(200, 250), interval))
        XCTAssertTrue(CalendarAccessController.overlaps(occurrence(50, 250), interval))
        XCTAssertTrue(CalendarAccessController.overlaps(occurrence(100, 100), interval))
        XCTAssertFalse(CalendarAccessController.overlaps(occurrence(200, 200), interval))
        XCTAssertFalse(CalendarAccessController.overlaps(occurrence(150, 140), interval))
    }
    func testIndependentChannelsAndInvalidRange() async {
        let backend = FakeBackend()
        backend.permissionValue = .authorized
        backend.descriptors = [descriptor("a")]
        backend.results = [event("month", at: 110), event("search", at: 310)]
        let controller = CalendarAccessController(backend: backend, storage: MemorySelection(["a"]), observeChanges: false)
        await controller.refresh(interval: interval)
        await controller.refresh(channel: .search, interval: DateInterval(start: Date(timeIntervalSince1970: 300), duration: 100))
        XCTAssertEqual(controller.events.map(\.eventID), ["month"])
        XCTAssertEqual(controller.snapshot(for: .search).events.map(\.eventID), ["search"])
        await controller.refresh(channel: .agenda, interval: DateInterval(start: interval.start, duration: 0))
        XCTAssertEqual(controller.snapshot(for: .agenda).state, .failed)
        backend.permissionValue = .denied
        await controller.refresh(channel: .reminders, interval: interval)
        XCTAssertTrue(controller.events.isEmpty)
        XCTAssertTrue(controller.snapshot(for: .search).events.isEmpty)
    }
    func testConcurrentChannelsKeepSeparateGenerations() async {
        let backend = FakeBackend()
        backend.permissionValue = .authorized
        backend.descriptors = [descriptor("a")]
        backend.suspendQueries = true
        let controller = CalendarAccessController(backend: backend, storage: MemorySelection(["a"]), observeChanges: false)
        let month = Task { await controller.refresh(interval: interval) }
        await waitFor { backend.pending.count == 1 }
        let search = Task { await controller.refresh(channel: .search, interval: interval) }
        await waitFor { backend.pending.count == 2 }
        backend.pending[1].resume(returning: [event("search", at: 110)])
        await search.value
        backend.pending[0].resume(returning: [event("month", at: 120)])
        await month.value
        XCTAssertEqual(controller.events.map(\.eventID), ["month"])
        XCTAssertEqual(controller.snapshot(for: .search).events.map(\.eventID), ["search"])
    }
    func testChunksDeduplicateAndPartialFailureNeverPublishes() async {
        let backend = FakeBackend()
        backend.permissionValue = .authorized
        backend.descriptors = [descriptor("a")]
        let duration = CalendarRangeQuery.chunkDuration
        let spanning = EventOccurrence(calendarID: "a", calendarName: "a", color: .init(red: 0, green: 0, blue: 0), eventID: "span", title: nil, start: interval.start, end: interval.start.addingTimeInterval(duration * 3), isAllDay: false)
        backend.results = [spanning, spanning]
        let controller = CalendarAccessController(backend: backend, storage: MemorySelection(["a"]), observeChanges: false)
        let range = DateInterval(start: interval.start, duration: duration * 2)
        await controller.refresh(channel: .search, interval: range)
        XCTAssertEqual(backend.queries.count, 2)
        XCTAssertEqual(controller.snapshot(for: .search).events.count, 1)
        backend.failOnQuery = 4
        await controller.refresh(channel: .search, interval: range)
        XCTAssertEqual(controller.snapshot(for: .search).state, .failed)
        XCTAssertTrue(controller.snapshot(for: .search).events.isEmpty)
    }
    func testResolutionRequiresCalendarIdentityAndOriginalRecurringAnchor() async throws {
        let original = OccurrenceAnchor.timed(Date(timeIntervalSince1970: 110))
        let identity = ReminderIdentity(calendarID: "a", localItemID: "item", externalID: "duplicate", confirmedSeriesKey: "series")
        func moved(_ item: String, calendar: String = "a", anchor: OccurrenceAnchor? = original) -> EventOccurrence {
            EventOccurrence(calendarID: calendar, calendarName: "Same", color: .init(red: 0, green: 0, blue: 0), eventID: item, title: nil, start: Date(timeIntervalSince1970: 999999999), end: Date(timeIntervalSince1970: 1000000000), isAllDay: false, localItemID: item, externalID: "duplicate", isRecurring: true, originalOccurrence: anchor, confirmedSeriesKey: item == "item" ? "series" : nil)
        }
        let event = moved("item")
        XCTAssertEqual(CalendarResolution.match([event], identity: identity, anchor: original, isRecurring: true, absence: .outsideQuery), .found(event))
        XCTAssertEqual(CalendarResolution.match([moved("other")], identity: identity, anchor: original, isRecurring: true, absence: .outsideQuery), .needsConfirmation)
        XCTAssertEqual(CalendarResolution.match([moved("item", calendar: "b")], identity: identity, anchor: original, isRecurring: true, absence: .outsideQuery), .outsideQuery)
        XCTAssertEqual(CalendarResolution.match([event, event], identity: identity, anchor: original, isRecurring: true, absence: .missing), .needsConfirmation)
        XCTAssertEqual(CalendarResolution.match([event], identity: identity, anchor: .timed(Date(timeIntervalSince1970: 120)), isRecurring: true, absence: .outsideQuery), .needsConfirmation)
        XCTAssertEqual(CalendarResolution.match([event], identity: identity, anchor: nil, isRecurring: false, absence: .missing), .found(event))
        let backend = FakeBackend()
        backend.permissionValue = .authorized
        backend.descriptors = [descriptor("a")]
        let controller = CalendarAccessController(backend: backend, storage: MemorySelection(["a"]), observeChanges: false)
        let outside = await controller.resolve(identity: identity, anchor: original, isRecurring: true)
        XCTAssertEqual(outside, .outsideQuery)
        let wrongScope = await controller.resolve(identity: .init(calendarID: "b", localItemID: "item"), anchor: original, isRecurring: true)
        XCTAssertEqual(wrongScope, .outsideSelectedScope)
    }
    func testChangeStreamBroadcastsWithoutMonthRange() async {
        let controller = CalendarAccessController(backend: FakeBackend(), storage: MemorySelection(), observeChanges: false)
        var first = controller.changes().makeAsyncIterator()
        var second = controller.changes().makeAsyncIterator()
        await controller.setSelectedCalendarIDs(["a"])
        let a = await first.next()
        let b = await second.next()
        if case .selection = a {} else { XCTFail("Missing first observer") }
        if case .selection = b {} else { XCTFail("Missing second observer") }
    }
    func testSelectionInvalidatesEverySuspendedChannel() async {
        let backend = FakeBackend()
        backend.permissionValue = .authorized
        backend.descriptors = [descriptor("a"), descriptor("b")]
        backend.suspendQueries = true
        let controller = CalendarAccessController(backend: backend, storage: MemorySelection(["a"]), observeChanges: false)
        let first = Task { await controller.refresh(channel: .search, interval: interval) }
        await waitFor { backend.pending.count == 1 }
        let second = Task { await controller.refresh(channel: .reminders, interval: interval) }
        await waitFor { backend.pending.count == 2 }
        // Empty selection refreshes without any query, while invalidating both reads.
        await controller.setSelectedCalendarIDs([])
        backend.pending[0].resume(returning: [event("stale", at: 110)])
        backend.pending[1].resume(returning: [event("stale", at: 110)])
        await first.value; await second.value
        XCTAssertEqual(controller.snapshot(for: .search).state, .selectionRequired)
        XCTAssertEqual(controller.snapshot(for: .reminders).state, .selectionRequired)
        XCTAssertTrue(controller.snapshot(for: .search).events.isEmpty)
        XCTAssertTrue(controller.snapshot(for: .reminders).events.isEmpty)
    }
    func testOriginalAnchorDedupPreservesDistinctOccurrences() async throws {
        let backend = FakeBackend()
        backend.permissionValue = .authorized
        func occurrence(_ start: Double, _ original: Double) -> EventOccurrence {
            EventOccurrence(calendarID: "a", calendarName: "a", color: .init(red: 0, green: 0, blue: 0), eventID: "item", title: nil, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: start + 1), isAllDay: false, localItemID: "item", isRecurring: true, originalOccurrence: .timed(Date(timeIntervalSince1970: original)), confirmedSeriesKey: "series")
        }
        backend.results = [occurrence(110, 105), occurrence(120, 105), occurrence(130, 125)]
        let values = try await CalendarRangeQuery.fetch(backend: backend, interval: interval, calendarIDs: ["a"])
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(Set(values.compactMap(\.originalOccurrence)).count, 2)
        XCTAssertTrue(CalendarRangeQuery.isValid(DateInterval(start: .distantPast, end: .distantFuture)))
    }
    private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<10000 { if predicate() { return }; await Task.yield() }
        XCTFail("Async operation did not reach expected checkpoint")
    }
    private func descriptor(_ id: String) -> CalendarDescriptor {
        CalendarDescriptor(id: id, name: "Same name", sourceName: id, color: .init(red: 1, green: 0, blue: 0))
    }
    private func event(_ id: String, at: Double, calendarID: String = "a") -> EventOccurrence {
        EventOccurrence(calendarID: calendarID, calendarName: "Same name", color: .init(red: 1, green: 0, blue: 0), eventID: id, title: nil, start: Date(timeIntervalSince1970: at), end: Date(timeIntervalSince1970: at), isAllDay: false)
    }
}
@MainActor final class MemorySelection: CalendarSelectionStorage {
    var ids: Set<String>
    init(_ ids: Set<String> = []) { self.ids = ids }
    func load() -> Set<String> { ids }
    func save(_ ids: Set<String>) { self.ids = ids }
}
@MainActor final class FakeBackend: CalendarBackend {
    var permissionValue: CalendarPermission = .unknown
    var descriptors: [CalendarDescriptor] = []
    var results: [EventOccurrence] = []
    var queries: [(DateInterval, Set<String>)] = []
    var pending: [CheckedContinuation<[EventOccurrence], Error>] = []
    var suspendQueries = false
    var suspendRequest = false
    var requestContinuation: CheckedContinuation<Void, Never>?
    var fail = false
    var failOnQuery: Int?
    func permission() async -> CalendarPermission { permissionValue }
    func requestAccess() async throws { if suspendRequest { await withCheckedContinuation { requestContinuation = $0 } } }
    func calendars() async throws -> [CalendarDescriptor] { descriptors }
    func events(interval: DateInterval, calendarIDs: Set<String>) async throws -> [EventOccurrence] {
        queries.append((interval, calendarIDs))
        if fail || queries.count == failOnQuery { throw NSError(domain: "test", code: 1) }
        if suspendQueries { return try await withCheckedThrowingContinuation { pending.append($0) } }
        return results
    }
}
