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
    func permission() async -> CalendarPermission { permissionValue }
    func requestAccess() async throws { if suspendRequest { await withCheckedContinuation { requestContinuation = $0 } } }
    func calendars() async throws -> [CalendarDescriptor] { descriptors }
    func events(interval: DateInterval, calendarIDs: Set<String>) async throws -> [EventOccurrence] {
        queries.append((interval, calendarIDs))
        if fail { throw NSError(domain: "test", code: 1) }
        if suspendQueries { return try await withCheckedThrowingContinuation { pending.append($0) } }
        return results
    }
}
