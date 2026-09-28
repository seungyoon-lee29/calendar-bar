import XCTest
import CalendarCore
@testable import CalendarNotifications

final class ReminderPersistenceTests: XCTestCase {
    func testAtomicRoundTripAndUnsupportedVersionPreserved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("reminders.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let storage = FileReminderStorage(url: url)
        var settings = ReminderSettings()
        settings.hideContent = true
        try storage.save(settings)
        XCTAssertTrue(try storage.load().hideContent)
        let bad = Data("{\"version\":99}".utf8)
        try bad.write(to: url)
        XCTAssertThrowsError(try storage.load())
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }
    func testStableOpaqueOccurrenceTriggerIdentity() throws {
        let identity = ReminderIdentity(calendarID: "private-calendar", localItemID: "private-event")
        let anchor = OccurrenceAnchor.timed(Date(timeIntervalSince1970: 2000000000))
        let a = try ReminderTrigger.timed(hours: 1, minutes: 0)
        let b = try ReminderTrigger.timed(hours: 0, minutes: 10)
        XCTAssertEqual(ReminderRequest.identifier(identity: identity, anchor: anchor, trigger: a), ReminderRequest.identifier(identity: identity, anchor: anchor, trigger: a))
        XCTAssertNotEqual(ReminderRequest.identifier(identity: identity, anchor: anchor, trigger: a), ReminderRequest.identifier(identity: identity, anchor: anchor, trigger: b))
        XCTAssertFalse(ReminderRequest.identifier(identity: identity, anchor: anchor, trigger: a).contains("private"))
    }
}

import CalendarAccess

private final class MemoryReminderStorage: ReminderStorage, @unchecked Sendable {
    var value = ReminderSettings()
    var fail = false
    var failLoad = false
    func load() throws -> ReminderSettings { if failLoad { throw ReminderStorageError.corrupt }; return value }
    func save(_ settings: ReminderSettings) throws { if fail { throw ReminderStorageError.unavailable }; value = settings }
}
@MainActor private final class Selection: CalendarSelectionStorage {
    func load() -> Set<String> { ["cal"] }
    func save(_ ids: Set<String>) {}
}
@MainActor private final class CalendarFake: CalendarBackend {
    var access: CalendarPermission = .authorized
    var items: [EventOccurrence] = []
    var fail = false
    var resolution: CalendarEventResolution = .missing
    var calendarIDs = ["cal"]
    func permission() async -> CalendarPermission { access }
    func requestAccess() async throws {}
    func calendars() async throws -> [CalendarDescriptor] { calendarIDs.map { CalendarDescriptor(id: $0, name: "", sourceName: "", color: RGBAColor(red: 0, green: 0, blue: 0)) } }
    func events(interval: DateInterval, calendarIDs: Set<String>) async throws -> [EventOccurrence] { if fail { throw ReminderStorageError.unavailable }; return items }
    func resolve(identity: ReminderIdentity, anchor: OccurrenceAnchor?, isRecurring: Bool, searchInterval: DateInterval?, calendarIDs: Set<String>) async throws -> CalendarEventResolution { resolution }
}
private actor NotificationFake: ReminderNotificationBackend {
    var requests: [String: ReminderRequest] = [:]
    var delivered: [String] = []
    var auth = ReminderPermission(authorizationRawValue: 2, alertRawValue: 2)
    var failAfter: Int?
    var additions = 0
    var requestFails = false
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    func permission() -> ReminderPermission { auth }
    func requestPermission() throws { if requestFails { throw ReminderStorageError.unavailable } }
    func failPermissionRequest() { requestFails = true }
    func pending() -> [ReminderRequest] { Array(requests.values) }
    func deliveredIdentifiers() -> [String] { delivered }
    func add(_ request: ReminderRequest) async throws {
        if hold { await withCheckedContinuation { continuation = $0 } }
        if let failAfter, additions >= failAfter { throw ReminderStorageError.unavailable }
        additions += 1; requests[request.id] = request
    }
    func remove(_ ids: [String]) { for id in ids { requests.removeValue(forKey: id) }; delivered.removeAll { ids.contains($0) } }
    func setFailure(_ count: Int?) { failAfter = count }
    func suspend() { hold = true }
    func suspended() -> Bool { continuation != nil }
    func resume() { hold = false; continuation?.resume(); continuation = nil }
    func markDelivered(_ ids: [String]) { delivered = ids }
    func deliver(_ ids: [String]) { for id in ids { requests.removeValue(forKey: id) }; delivered = ids }
    func deny() { auth = ReminderPermission(authorizationRawValue: 1, alertRawValue: 1) }
}
@MainActor final class ReminderCoordinatorTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    func event(_ offset: TimeInterval = 7200) -> EventOccurrence {
        EventOccurrence(calendarID: "cal", calendarName: "", color: RGBAColor(red: 0, green: 0, blue: 0), eventID: "item", title: "PRIVATE TITLE", start: now.addingTimeInterval(offset), end: now.addingTimeInterval(offset + 60), isAllDay: false)
    }
    func rule(_ event: EventOccurrence, enabled: Bool = true) throws -> ReminderRule {
        try ReminderRule(identity: event.reminderIdentity, anchor: .timed(event.start), scope: .thisOccurrence, format: .timed, enabled: enabled, triggers: ReminderDefaults().timed)
    }
    private func coordinator(_ calendar: CalendarFake, _ notifications: NotificationFake, _ storage: MemoryReminderStorage = MemoryReminderStorage(), budget: Int = 48) -> ReminderCoordinator {
        let time = now
        return ReminderCoordinator(access: CalendarAccessController(backend: calendar, storage: Selection(), observeChanges: false), storage: storage, backend: notifications, now: { time }, budget: budget, observeChanges: false)
    }
    func testMultipleTriggersPendingEvidenceDefaultsSnapshotAndHide() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let storage = MemoryReminderStorage()
        let item = event(); calendar.items = [item]
        let model = coordinator(calendar, backend, storage)
        let initial = try rule(item)
        try await model.save(rule: initial, event: item)
        XCTAssertEqual(model.scheduled, 2)
        XCTAssertEqual(model.snapshots[initial.id]?.state, .scheduled)
        try await model.updateDefaults(ReminderDefaults(timed: [try .timed(hours: 2, minutes: 0)]))
        XCTAssertEqual(model.settings.rules.rules.first?.triggers.count, 2)
        try await model.setHideContent(true)
        let pending = await backend.pending()
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.allSatisfy { !$0.title.contains("PRIVATE") && $0.body == "캘린더에서 일정을 확인하세요." })
        XCTAssertFalse(String(data: try JSONEncoder().encode(storage.value), encoding: .utf8)!.contains("PRIVATE"))
        XCTAssertNotNil(model.clickLink(token: pending[0].token))
        await model.refresh()
        XCTAssertEqual(model.scheduled, 2)
    }
    func testPartialCapacityAndBackendFailureEvidence() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let item = event(); calendar.items = [item]
        let model = coordinator(calendar, backend, budget: 1)
        let rule = try rule(item); try await model.save(rule: rule, event: item)
        XCTAssertEqual(model.scheduled, 1); XCTAssertEqual(model.deferred, 1)
        XCTAssertEqual(model.snapshots[rule.id]?.state, .partial)
        let backend2 = NotificationFake(); await backend2.setFailure(1)
        let model2 = coordinator(calendar, backend2)
        try await model2.save(rule: rule, event: item)
        XCTAssertEqual(model2.scheduled, 1); XCTAssertEqual(model2.snapshots[rule.id]?.state, .partial)
        await backend2.setFailure(nil); await model2.refresh()
        XCTAssertEqual(model2.scheduled, 2)
    }
    func testQueryFailurePreservesThenMissingAndAmbiguityCancel() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let item = event(); calendar.items = [item]
        let model = coordinator(calendar, backend); let rule = try rule(item)
        try await model.save(rule: rule, event: item)
        calendar.fail = true; await model.refresh()
        XCTAssertEqual(model.snapshots[rule.id]?.state, .failed)
        let kept = await backend.pending(); XCTAssertEqual(kept.count, 2)
        calendar.fail = false; calendar.items = []; calendar.resolution = .needsConfirmation
        await model.refresh(); XCTAssertEqual(model.needsConfirmation, 1)
        let canceled = await backend.pending(); XCTAssertTrue(canceled.isEmpty)
        calendar.resolution = .missing; await model.refresh()
        XCTAssertEqual(model.snapshots[rule.id]?.state, .noFuture)
    }
    func testStorageFailureAndUnknownRecurrenceDoNotPretendSaved() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let storage = MemoryReminderStorage(); let item = event(); calendar.items = [item]
        let model = coordinator(calendar, backend, storage)
        do { try await model.save(rule: rule(item)); XCTFail("requires event evidence") } catch {}
        storage.fail = true
        do { try await model.save(rule: rule(item), event: item); XCTFail("save must fail") } catch {}
        XCTAssertTrue(model.settings.rules.rules.isEmpty)
        let pending = await backend.pending(); XCTAssertTrue(pending.isEmpty)
    }
    func testSuspendedAddCannotResurrectAfterOffOrHide() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let item = event(); calendar.items = [item]
        let model = coordinator(calendar, backend); await backend.suspend()
        let onRule = try rule(item)
        let enabling = Task { try await model.save(rule: onRule, event: item) }
        for _ in 0..<1000 { if await backend.suspended() { break }; await Task.yield() }
        let held = await backend.suspended(); XCTAssertTrue(held)
        let disabling = Task { try await model.save(rule: rule(item, enabled: false), event: item) }
        for _ in 0..<100 { await Task.yield() }
        await backend.resume(); try await enabling.value; try await disabling.value
        let pending = await backend.pending(); XCTAssertTrue(pending.isEmpty)
        XCTAssertFalse(model.settings.rules.rules.last!.enabled)
        await backend.suspend()
        let again = Task { try await model.save(rule: onRule, event: item) }
        for _ in 0..<1000 { if await backend.suspended() { break }; await Task.yield() }
        let hiding = Task { try await model.setHideContent(true) }
        for _ in 0..<100 { await Task.yield() }
        await backend.resume(); try await again.value; try await hiding.value
        let hidden = await backend.pending(); XCTAssertEqual(hidden.count, 2)
        XCTAssertTrue(hidden.allSatisfy { $0.title == "일정 알림" })
    }
    func testPermissionLossAndNormalExit() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let item = event(); calendar.items = [item]
        var model: ReminderCoordinator? = coordinator(calendar, backend)
        try await model!.save(rule: rule(item), event: item)
        weak let weakModel = model; model = nil
        XCTAssertNil(weakModel)
        let retained = await backend.pending(); XCTAssertEqual(retained.count, 2)
        let model2 = coordinator(calendar, backend)
        try await model2.save(rule: rule(item), event: item)
        calendar.access = .denied; await model2.refresh()
        let canceled = await backend.pending(); XCTAssertTrue(canceled.isEmpty)
        XCTAssertEqual(model2.snapshots.values.first?.state, .permissionRequired)
    }
}

@MainActor extension ReminderCoordinatorTests {
    func testOccurrenceOverrideSurvivesSeriesEditAndRemovalRestores() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake()
        func recurring(_ offset: TimeInterval) -> EventOccurrence {
            let date = now.addingTimeInterval(offset)
            return EventOccurrence(calendarID: "cal", calendarName: "", color: RGBAColor(red: 0, green: 0, blue: 0), eventID: "series", title: "PRIVATE", start: date, end: date.addingTimeInterval(60), isAllDay: false, isRecurring: true, originalOccurrence: .timed(date), confirmedSeriesKey: "master")
        }
        let first = recurring(7200); let second = recurring(86400)
        calendar.items = [first, second]
        let model = coordinator(calendar, backend)
        let series = try ReminderRule(identity: first.reminderIdentity, anchor: .timed(first.start), scope: .thisAndFuture, format: .timed, enabled: true, triggers: ReminderDefaults().timed)
        try await model.save(rule: series, event: first)
        XCTAssertEqual(model.scheduled, 4)
        let off = try ReminderRule(identity: second.reminderIdentity, anchor: .timed(second.start), scope: .thisOccurrence, format: .timed, enabled: false, triggers: [])
        try await model.save(rule: off, event: second)
        XCTAssertEqual(model.scheduled, 2)
        let changed = try ReminderRule(identity: first.reminderIdentity, anchor: .timed(first.start), scope: .thisAndFuture, format: .timed, enabled: true, triggers: [try .timed(hours: 0, minutes: 10)])
        try await model.save(rule: changed, event: first)
        XCTAssertEqual(model.scheduled, 1)
        XCTAssertTrue(model.settings.rules.rules.contains { $0.id == off.id })
        try await model.removeOverride(identity: second.reminderIdentity, anchor: .timed(second.start))
        XCTAssertEqual(model.scheduled, 2)
        let pending = await backend.pending(); XCTAssertEqual(Set(pending.map(\.id)).count, 2)
    }
    func testFarFutureDirectResolutionAndMovedNonrecurringAnchor() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let item = event(800 * 86400)
        calendar.resolution = .found(item)
        let model = coordinator(calendar, backend)
        let original = try rule(item)
        try await model.save(rule: original, event: item)
        XCTAssertEqual(model.scheduled, 2)
        let oldIDs = Set(await backend.pending().map(\.id))
        let moved = event(900 * 86400); calendar.resolution = .found(moved)
        let edited = try ReminderRule(id: original.id, identity: original.identity, anchor: .timed(moved.start), scope: .thisOccurrence, format: .timed, enabled: true, triggers: original.triggers)
        try await model.save(rule: edited, event: moved)
        XCTAssertEqual(model.settings.rules.rules.first?.anchor, original.anchor)
        let newIDs = Set(await backend.pending().map(\.id)); XCTAssertEqual(oldIDs, newIDs)
    }
    func testRefillSkipsPastAndDeletionClearsDelivered() async throws {
        final class Clock: @unchecked Sendable { var value: Date; init(_ value: Date) { self.value = value } }
        let clock = Clock(now); let calendar = CalendarFake(); let backend = NotificationFake(); let item = event(); calendar.items = [item]
        let model = ReminderCoordinator(access: CalendarAccessController(backend: calendar, storage: Selection(), observeChanges: false), storage: MemoryReminderStorage(), backend: backend, now: { clock.value }, budget: 1, observeChanges: false)
        let rule = try rule(item); try await model.save(rule: rule, event: item)
        let first = await backend.pending(); XCTAssertEqual(first.count, 1)
        clock.value = now.addingTimeInterval(3700)
        await model.refresh()
        let refilled = await backend.pending(); XCTAssertEqual(refilled.count, 1)
        XCTAssertNotEqual(first.first?.id, refilled.first?.id)
        XCTAssertEqual(model.deferred, 0)
        await backend.markDelivered(first.map(\.id))
        calendar.items = []; calendar.resolution = .missing
        await model.refresh()
        let delivered = await backend.deliveredIdentifiers(); XCTAssertTrue(delivered.isEmpty)
    }
    func testChangeStreamPermissionRaceAndLifecycle() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let item = event(); calendar.items = [item]
        let access = CalendarAccessController(backend: calendar, storage: Selection(), observeChanges: false)
        let time = now
        var model: ReminderCoordinator? = ReminderCoordinator(access: access, storage: MemoryReminderStorage(), backend: backend, now: { time }, observeChanges: true)
        await model!.refresh()
        await backend.suspend()
        let retained = model!
        let enabling = Task { try await retained.save(rule: rule(item), event: item) }
        for _ in 0..<1000 { if await backend.suspended() { break }; await Task.yield() }
        calendar.access = .denied
        await access.invalidate(reason: .permission)
        for _ in 0..<100 { await Task.yield() }
        await backend.resume(); try await enabling.value
        await model!.refresh()
        let pending = await backend.pending(); XCTAssertTrue(pending.isEmpty)
        model = nil
    }
}

@MainActor extension ReminderCoordinatorTests {
    func testHiddenContentSurvivesFailedResolutionAndRestart() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let storage = MemoryReminderStorage(); let item = event(); calendar.items = [item]
        let model = coordinator(calendar, backend, storage)
        try await model.save(rule: rule(item), event: item)
        let original = await backend.pending()
        await backend.markDelivered(original.map(\.id))
        calendar.items = []; calendar.resolution = .failed
        try await model.setHideContent(true)
        let hidden = await backend.pending(); XCTAssertTrue(hidden.allSatisfy { $0.title == "일정 알림" })
        let delivered = await backend.deliveredIdentifiers(); XCTAssertTrue(delivered.isEmpty)
        // Simulate a process crash after the durable privacy setting changed but
        // before prior displayed content could be removed.
        await backend.markDelivered(original.map(\.id))
        let restarted = coordinator(calendar, backend, storage)
        await restarted.refresh()
        let afterRestart = await backend.deliveredIdentifiers(); XCTAssertTrue(afterRestart.isEmpty)
        let persistedHidden = await backend.pending(); XCTAssertTrue(persistedHidden.allSatisfy { !$0.title.contains("PRIVATE") })
    }
}

@MainActor extension ReminderCoordinatorTests {
    func testReviewOffAndSelectionStillCancelDuringQueryFailure() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let item = event(); calendar.items = [item]
        let access = CalendarAccessController(backend: calendar, storage: Selection(), observeChanges: false)
        let time = now
        let model = ReminderCoordinator(access: access, storage: MemoryReminderStorage(), backend: backend, now: { time }, observeChanges: false)
        try await model.save(rule: rule(item), event: item)
        let original = await backend.pending(); await backend.markDelivered(original.map(\.id))
        calendar.fail = true
        try await model.save(rule: rule(item, enabled: false), event: item)
        var pending = await backend.pending(); XCTAssertTrue(pending.isEmpty)
        var delivered = await backend.deliveredIdentifiers(); XCTAssertTrue(delivered.isEmpty)
        calendar.fail = false; try await model.save(rule: rule(item), event: item)
        calendar.calendarIDs = ["cal", "other"]; calendar.fail = true
        await access.setSelectedCalendarIDs(["other"]); await model.refresh()
        pending = await backend.pending(); delivered = await backend.deliveredIdentifiers()
        XCTAssertTrue(pending.isEmpty); XCTAssertTrue(delivered.isEmpty)
    }
    func testReviewCorruptStorageCannotBlockPermissionCleanup() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let storage = MemoryReminderStorage(); let item = event(); calendar.items = [item]
        let model = coordinator(calendar, backend, storage); try await model.save(rule: rule(item), event: item)
        let pending = await backend.pending(); await backend.markDelivered(pending.map(\.id) + ["other.app"])
        let foreign = ReminderRequest(id: "other.app", fireDate: item.start, title: "foreign", body: "", token: "foreign")
        try await backend.add(foreign)
        storage.failLoad = true; calendar.access = .denied
        let broken = coordinator(calendar, backend, storage); await broken.refresh()
        let remaining = await backend.pending(); XCTAssertEqual(remaining.map(\.id), ["other.app"])
        let delivered = await backend.deliveredIdentifiers(); XCTAssertEqual(delivered, ["other.app"])
        XCTAssertNotNil(broken.storageError)
    }
    func testReviewFormatChangeIsOccurrenceScoped() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake()
        func occurrence(_ offset: TimeInterval, allDay: Bool = false, unknown: Bool = false) -> EventOccurrence {
            let start = now.addingTimeInterval(offset)
            return EventOccurrence(calendarID: "cal", calendarName: "", color: RGBAColor(red: 0, green: 0, blue: 0), eventID: "series", title: "", start: start, end: start.addingTimeInterval(60), isAllDay: allDay, isRecurring: true, originalOccurrence: unknown ? nil : .timed(start), confirmedSeriesKey: "master")
        }
        let a = occurrence(7200), b = occurrence(14400), c = occurrence(21600)
        calendar.items = [a,b,c]
        let model = coordinator(calendar, backend)
        let series = try ReminderRule(identity: a.reminderIdentity, anchor: .timed(a.start), scope: .thisAndFuture, format: .timed, enabled: true, triggers: ReminderDefaults().timed)
        try await model.save(rule: series, event: a)
        let changed = occurrence(21600, allDay: true); calendar.items = [a,b,changed]; await model.refresh()
        XCTAssertEqual(model.scheduled, 4); XCTAssertEqual(model.snapshot(for: a).state, .scheduled)
        XCTAssertEqual(model.snapshot(for: changed).state, .needsConfirmation)
        let unknown = occurrence(21600, unknown: true); calendar.items = [a,b,unknown]; await model.refresh()
        XCTAssertEqual(model.scheduled, 4); XCTAssertEqual(model.snapshot(for: b).state, .scheduled)
        XCTAssertEqual(model.snapshot(for: unknown).state, .needsConfirmation)
    }
    func testReviewDeliveredOccurrenceUsesCurrentOverrideAndDeletion() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake()
        func occurrence(_ offset: TimeInterval) -> EventOccurrence {
            let start = now.addingTimeInterval(offset)
            return EventOccurrence(calendarID: "cal", calendarName: "", color: RGBAColor(red: 0, green: 0, blue: 0), eventID: "series", title: "", start: start, end: start.addingTimeInterval(60), isAllDay: false, isRecurring: true, originalOccurrence: .timed(start), confirmedSeriesKey: "master")
        }
        let a = occurrence(7200), b = occurrence(14400); calendar.items = [a,b]
        let model = coordinator(calendar, backend)
        let series = try ReminderRule(identity: a.reminderIdentity, anchor: .timed(a.start), scope: .thisAndFuture, format: .timed, enabled: true, triggers: ReminderDefaults().timed)
        try await model.save(rule: series, event: a)
        let pending = await backend.pending(); let aIDs = pending.filter { model.clickLink(token: $0.token)?.anchor == .timed(a.start) }.map(\.id)
        await backend.deliver(aIDs)
        let off = try ReminderRule(identity: a.reminderIdentity, anchor: .timed(a.start), scope: .thisOccurrence, format: .timed, enabled: false, triggers: [])
        try await model.save(rule: off, event: a)
        var delivered = await backend.deliveredIdentifiers(); XCTAssertTrue(delivered.isEmpty); XCTAssertEqual(model.scheduled, 2)
        try await model.removeOverride(identity: a.reminderIdentity, anchor: .timed(a.start))
        await backend.deliver(aIDs); calendar.items = [b]; calendar.resolution = .missing
        await model.refresh(); delivered = await backend.deliveredIdentifiers()
        XCTAssertTrue(delivered.isEmpty); XCTAssertEqual(model.scheduled, 2)
    }
    func testReviewEventSnapshotPreservesTriggerFailure() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let item = event(); calendar.items = [item]
        await backend.setFailure(1)
        let model = coordinator(calendar, backend); try await model.save(rule: rule(item), event: item)
        XCTAssertEqual(model.snapshot(for: item).scheduled, 1)
        XCTAssertEqual(model.snapshot(for: item).state, .partial)
    }
    func testReviewHideAndFullQueryFailureKeepsGenericRequests() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let item = event(); calendar.items = [item]
        let model = coordinator(calendar, backend); try await model.save(rule: rule(item), event: item)
        let before = await backend.pending(); await backend.markDelivered(before.map(\.id))
        calendar.fail = true; try await model.setHideContent(true)
        let after = await backend.pending()
        XCTAssertEqual(Set(before.map(\.id)), Set(after.map(\.id)))
        XCTAssertTrue(after.allSatisfy { $0.title == "일정 알림" && $0.body == "캘린더에서 일정을 확인하세요." })
        let delivered = await backend.deliveredIdentifiers(); XCTAssertTrue(delivered.isEmpty)
    }
    func testReviewPermissionRequestFailureObservable() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let model = coordinator(calendar, backend)
        await backend.failPermissionRequest(); await model.requestPermission()
        XCTAssertNotNil(model.permissionRequestError)
        XCTAssertTrue(model.permission.canSchedule)
    }
}

@MainActor extension ReminderCoordinatorTests {
    func testTimerRearmingCancellationAndDeallocation() async {
        let calendar = CalendarFake(); let backend = NotificationFake(); let time = now
        var model: ReminderCoordinator? = ReminderCoordinator(access: CalendarAccessController(backend: calendar, storage: Selection(), observeChanges: false), storage: MemoryReminderStorage(), backend: backend, now: { time }, observeChanges: true)
        for _ in 0..<100 { await model!.refresh() }
        weak let released = model; model = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(released)
    }
    func testFailedQueryPreservesOtherRuleAndRemovingOverrideCancels() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let a = event()
        let b = EventOccurrence(calendarID: "cal", calendarName: "", color: a.color, eventID: "other", title: "", start: a.start, end: a.end, isAllDay: false)
        calendar.items = [a,b]
        let model = coordinator(calendar, backend)
        try await model.save(rule: rule(a), event: a); try await model.save(rule: rule(b), event: b)
        calendar.fail = true
        try await model.save(rule: rule(a, enabled: false), event: a)
        var pending = await backend.pending(); XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.allSatisfy { model.clickLink(token: $0.token)?.identity.localItemID == "other" })
        try await model.removeOverride(identity: b.reminderIdentity, anchor: .timed(b.start))
        pending = await backend.pending(); XCTAssertTrue(pending.isEmpty)
    }
    func testUnreadableFilePreservedWhileUnverifiableScopeIsPurged() async throws {
        let calendar = CalendarFake(); let backend = NotificationFake(); let item = event(); calendar.items = [item]
        let original = coordinator(calendar, backend); try await original.save(rule: rule(item), event: item)
        let known = await backend.pending()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let time = now
        for bytes in [Data("broken".utf8), Data("{\"version\":99}".utf8)] {
            for request in known { try await backend.add(request) }
            await backend.markDelivered(known.map(\.id))
            try bytes.write(to: url)
            let model = ReminderCoordinator(access: CalendarAccessController(backend: calendar, storage: Selection(), observeChanges: false), storage: FileReminderStorage(url: url), backend: backend, now: { time }, observeChanges: false)
            await model.refresh()
            let pending = await backend.pending(); let delivered = await backend.deliveredIdentifiers()
            XCTAssertTrue(pending.isEmpty); XCTAssertTrue(delivered.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertNotNil(model.storageError)
        }
    }
}
