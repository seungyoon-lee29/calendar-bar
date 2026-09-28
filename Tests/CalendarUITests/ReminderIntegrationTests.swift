import XCTest
import CalendarCore
import CalendarAccess
import CalendarNotifications
@testable import CalendarUI

final class ReminderIntegrationTests: XCTestCase {
    func testNotificationReportRequiresBothExplicitFlagAndSeparateQABundle() {
        let flag = "--qa-notification-report"
        XCTAssertEqual(CalendarLaunchOptions.notificationReportMode(arguments: ["app", flag], bundleID: "test.calendar.qa"), .readOnly)
        XCTAssertEqual(CalendarLaunchOptions.notificationReportMode(arguments: ["app"], bundleID: "test.calendar.qa"), .none)
        XCTAssertEqual(CalendarLaunchOptions.notificationReportMode(arguments: ["app", "--qa", flag], bundleID: "test.calendar"), .denied)
        XCTAssertEqual(CalendarLaunchOptions.notificationReportMode(arguments: ["app", flag], bundleID: nil), .denied)
        XCTAssertEqual(CalendarLaunchOptions.notificationReportMode(arguments: ["app", flag], bundleID: "test.calendar.qa.other"), .denied)
    }

    func testQAColdLaunchWithoutArgumentsKeepsIsolationAndSeed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("qa-launch.json")
        let warm = CalendarLaunchOptions(arguments: ["app", "--qa", "--qa-notifications", "--qa-seed", "1800000000"], bundleID: "test.calendar.qa", qaConfigurationURL: url)
        let cold = CalendarLaunchOptions(arguments: ["app"], bundleID: "test.calendar.qa", qaConfigurationURL: url)
        XCTAssertTrue(cold.qa)
        XCTAssertTrue(cold.qaNotifications)
        XCTAssertEqual(cold.qaSeed, warm.qaSeed)
        let ordinary = CalendarLaunchOptions(arguments: ["app", "--qa", "--qa-notifications"], bundleID: "test.calendar", qaConfigurationURL: url)
        XCTAssertTrue(ordinary.qa)
        XCTAssertFalse(ordinary.qaNotifications)
        XCTAssertNil(ordinary.qaSeed)
        let production = CalendarLaunchOptions(arguments: ["app"], bundleID: "test.calendar", qaConfigurationURL: url)
        XCTAssertFalse(production.qa)
        XCTAssertFalse(production.qaNotifications)
    }

    @MainActor func testColdAndWarmClickQueue() async {
        let router = ReminderClickRouter()
        var values: [String] = []
        router.receive("cold")
        XCTAssertTrue(values.isEmpty)
        router.install { values.append($0) }
        await router.waitUntilIdle()
        router.receive("warm")
        await router.waitUntilIdle()
        XCTAssertEqual(values, ["cold", "warm"])
    }
    @MainActor func testRoutingResolvesCurrentEventAndInvalidatesOldMonthCompletion() async throws {
        let now = Date()
        let access = CalendarAccessController(backend: QACalendarBackend(now: now), storage: QASelection(), observeChanges: false)
        let backend = QANotifications()
        let reminders = ReminderCoordinator(access: access, storage: VolatileReminderStorage(), backend: backend, observeChanges: false)
        let model = CalendarModel(access: access, reminders: reminders)
        model.refresh(); await model.waitForRefresh()
        let event = try XCTUnwrap(access.events.first { $0.eventID == "qa-timed" })
        model.editReminder(event)
        await model.saveReminder(enabled: true)
        XCTAssertTrue(reminders.settings.rules.rules.count == 1)
        XCTAssertEqual(reminders.snapshot(for: event).state, .permissionRequired)
        await reminders.requestPermission()
        let token = try XCTUnwrap(reminders.settings.links.keys.first)
        let target = try XCTUnwrap(reminders.clickLink(token: token))
        let oldPresentation = model.presentationID
        model.open()
        await model.routeReminder(token: token)
        XCTAssertNotEqual(oldPresentation, model.presentationID)
        XCTAssertNil(model.selectedReminderEvent)
        XCTAssertNil(model.navigationMessage)
        XCTAssertEqual(model.highlightedEventID, event.id)
        XCTAssertEqual(target.identity, event.reminderIdentity)
        await model.waitForRefresh()
        await access.setSelectedCalendarIDs([])
        await model.routeReminder(token: token)
        XCTAssertNotNil(model.navigationMessage)
        XCTAssertNil(model.selectedReminderEvent)
    }
    @MainActor func testSelectionAndPermissionLossClearPrivateEditor() async throws {
        let backend = MutableReminderCalendar()
        let access = CalendarAccessController(backend: backend, storage: QASelection(), observeChanges: false)
        let reminders = ReminderCoordinator(access: access, storage: VolatileReminderStorage(), backend: QANotifications(), observeChanges: false)
        let model = CalendarModel(access: access, reminders: reminders)
        model.refresh(); await model.waitForRefresh()
        let event = try XCTUnwrap(access.events.first)
        model.editReminder(event)
        XCTAssertNotNil(model.reminderDraft)
        await access.setSelectedCalendarIDs([])
        await Task.yield()
        model.clearInaccessibleEditor()
        XCTAssertNil(model.reminderDraft)
        XCTAssertNil(model.selectedReminderEvent)
        await access.setSelectedCalendarIDs(["qa-calendar"])
        model.editReminder(event)
        await backend.deny()
        await access.invalidate(reason: .permission)
        await Task.yield()
        model.clearInaccessibleEditor()
        XCTAssertNil(model.reminderDraft)
        XCTAssertFalse(model.canDisplayReminder)
    }
    @MainActor func testFormatChangeDuringEditingRequiresNewInputBeforeSave() async throws {
        let backend = MutableReminderCalendar()
        let access = CalendarAccessController(backend: backend, storage: QASelection(), observeChanges: false)
        let reminders = ReminderCoordinator(access: access, storage: VolatileReminderStorage(), backend: QANotifications(), observeChanges: false)
        let model = CalendarModel(access: access, reminders: reminders)
        model.refresh(); await model.waitForRefresh()
        let event = try XCTUnwrap(access.events.first { $0.eventID == "qa-timed" })
        model.editReminder(event)
        await model.saveReminder(enabled: true)
        let original = try XCTUnwrap(reminders.settings.rules.rules.first)
        await backend.convert()
        await model.saveReminder(enabled: true)
        XCTAssertTrue(try XCTUnwrap(model.reminderDraft).requiresFormatConfirmation)
        XCTAssertEqual(model.reminderDraft?.format, .allDay)
        XCTAssertEqual(reminders.settings.rules.rules.first, original)
        XCTAssertNotNil(model.reminderError)
        model.reminderDraft?.formatConfirmed = true
        await model.saveReminder(enabled: true)
        XCTAssertEqual(reminders.settings.rules.rules.first?.anchor, original.anchor)
        XCTAssertEqual(reminders.settings.rules.rules.first?.id, original.id)
        XCTAssertEqual(reminders.settings.rules.rules.first?.format, .allDay)
    }
    @MainActor func testCancelledEditorCannotReturnAfterSlowSave() async throws {
        let backend = MutableReminderCalendar()
        let access = CalendarAccessController(backend: backend, storage: QASelection(), observeChanges: false)
        let reminders = ReminderCoordinator(access: access, storage: VolatileReminderStorage(), backend: QANotifications(), observeChanges: false)
        let model = CalendarModel(access: access, reminders: reminders)
        model.refresh(); await model.waitForRefresh()
        let event = try XCTUnwrap(access.events.first { $0.eventID == "qa-timed" })
        model.editReminder(event)
        await backend.delay()
        let save = Task { await model.saveReminder(enabled: true) }
        while !model.reminderBusy { await Task.yield() }
        model.cancelReminder()
        await save.value
        XCTAssertNil(model.selectedReminderEvent)
        XCTAssertNil(model.reminderDraft)
        XCTAssertTrue(reminders.settings.rules.rules.isEmpty)
    }
    @MainActor func testSaveFailureDoesNotPretendSuccessAndPermissionFailureIsVisible() async throws {
        let access = CalendarAccessController(backend: QACalendarBackend(), storage: QASelection(), observeChanges: false)
        let reminders = ReminderCoordinator(access: access, storage: FailingReminderStorage(), backend: FailingNotifications(), observeChanges: false)
        let model = CalendarModel(access: access, reminders: reminders)
        model.refresh(); await model.waitForRefresh()
        model.editReminder(try XCTUnwrap(access.events.first))
        await model.saveReminder(enabled: true)
        XCTAssertNotNil(model.reminderError)
        XCTAssertTrue(reminders.settings.rules.rules.isEmpty)
        await reminders.requestPermission()
        XCTAssertNotNil(reminders.permissionRequestError)
    }
    @MainActor func testActualPartialDeliveryAndDefaultsDoNotRewriteRules() async throws {
        let access = CalendarAccessController(backend: QACalendarBackend(), storage: QASelection(), observeChanges: false)
        let backend = QANotifications()
        let reminders = ReminderCoordinator(access: access, storage: VolatileReminderStorage(), backend: backend, budget: 1, observeChanges: false)
        let model = CalendarModel(access: access, reminders: reminders)
        model.refresh(); await model.waitForRefresh()
        let event = try XCTUnwrap(access.events.first { $0.eventID == "qa-timed" })
        model.editReminder(event)
        await model.saveReminder(enabled: true)
        await reminders.requestPermission()
        let before = reminders.settings.rules
        try await reminders.updateDefaults(ReminderDefaults(timed: [try .timed(hours: 0, minutes: 5)]))
        XCTAssertEqual(reminders.settings.rules, before)
        let snapshot = reminders.snapshot(for: event)
        XCTAssertEqual(snapshot.state, .partial)
        XCTAssertEqual(snapshot.scheduled, 1)
        XCTAssertEqual(snapshot.deferred, 1)
        XCTAssertTrue(snapshot.desiredEnabled)
    }
}
private actor MutableReminderCalendar: CalendarBackend {
    let base = QACalendarBackend()
    var permissionValue: CalendarPermission = .authorized
    var converted = false
    var delayed = false
    func convert() { converted = true }
    func delay() { delayed = true }
    func deny() { permissionValue = .denied }
    func permission() async -> CalendarPermission { permissionValue }
    func requestAccess() async throws {}
    func calendars() async throws -> [CalendarDescriptor] { try await base.calendars() }
    func events(interval: DateInterval, calendarIDs: Set<String>) async throws -> [EventOccurrence] {
        if delayed { try await Task.sleep(for: .milliseconds(60)) }
        let values = try await base.events(interval: interval, calendarIDs: calendarIDs)
        return values.map { event in
            guard converted, event.eventID == "qa-timed" else { return event }
            return EventOccurrence(calendarID: event.calendarID, calendarName: event.calendarName, color: event.color, eventID: event.eventID, title: event.title, start: event.start, end: event.end, isAllDay: true)
        }
    }
}
private struct FailingReminderStorage: ReminderStorage {
    func load() throws -> ReminderSettings { ReminderSettings() }
    func save(_ settings: ReminderSettings) throws { throw ReminderStorageError.unavailable }
}
private actor FailingNotifications: ReminderNotificationBackend {
    func permission() async -> ReminderPermission { .init(authorizationRawValue: 0, alertRawValue: 0) }
    func requestPermission() async throws { throw ReminderStorageError.unavailable }
    func pending() async -> [ReminderRequest] { [] }
    func add(_ request: ReminderRequest) async throws {}
    func remove(_ identifiers: [String]) async {}
    func deliveredIdentifiers() async -> [String] { [] }
}
