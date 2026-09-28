import XCTest
@testable import CalendarCore

final class PlanningTests: XCTestCase {
    let context = CalendarContext(timeZone: TimeZone(secondsFromGMT: 0)!)
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    func event(_ id: String = "e", title: String = "Café Planning", start: String = "2024-03-01T10:00:00Z", end: String = "2024-03-03T00:00:00Z", allDay: Bool = false) -> EventOccurrence {
        EventOccurrence(calendarID: "c", calendarName: "", color: .init(red: 0, green: 0, blue: 0), eventID: id, title: title, start: date(start), end: date(end), isAllDay: allDay)
    }
    func testSearchAndDailyGrouping() throws {
        let range = try EventSearch.interval(startDate: date("2024-03-01T12:00:00Z"), endDate: date("2024-03-03T12:00:00Z"), context: context)
        XCTAssertEqual(range.end, date("2024-03-04T00:00:00Z"))
        XCTAssertThrowsError(try EventSearch.interval(startDate: range.end, endDate: range.start, context: context))
        let e = event()
        XCTAssertEqual(EventSearch.results(query: " CAFE\u{301} PLANNING ", events: [e,e], selectedCalendarIDs: ["c"], interval: range).count, 1)
        XCTAssertTrue(EventSearch.results(query: "Planning Café", events: [e], selectedCalendarIDs: ["c"], interval: range).isEmpty)
        XCTAssertTrue(EventSearch.results(query: " ", events: [e], selectedCalendarIDs: ["c"], interval: range).isEmpty)
        XCTAssertTrue(EventSearch.results(query: "café", events: [e], selectedCalendarIDs: [], interval: range).isEmpty)
        let zero = event("zero", start: "2024-03-03T00:00:00Z", end: "2024-03-03T00:00:00Z")
        let all = event("all", start: "2024-03-01T00:00:00Z", end: "2024-03-03T00:00:00Z", allDay: true)
        let groups = AgendaIndex.groups(events: [e,e,zero,all], interval: range, context: context)
        XCTAssertEqual(groups.map { $0.events.map(\.eventID) }, [["all","e"],["all","e"],["zero"]])
    }
    func testTriggerValidationAndSnapshot() throws {
        XCTAssertThrowsError(try ReminderTrigger.timed(hours: Int.max, minutes: 0))
        XCTAssertThrowsError(try ReminderTrigger.timed(hours: 0, minutes: 0))
        XCTAssertThrowsError(try ReminderTrigger.allDay(daysBefore: -1, hour: 21, minute: 0))
        let identity = ReminderIdentity(calendarID: "c", localItemID: "i", confirmedSeriesKey: "s")
        let anchor = OccurrenceAnchor.timed(date("2024-03-01T10:00:00Z"))
        var defaults = ReminderDefaults()
        let rule = try defaults.rule(identity: identity, anchor: anchor, scope: .thisOccurrence, format: .timed)
        defaults.timed = [try .timed(hours: 2, minutes: 0)]
        XCTAssertEqual(rule.triggers.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(ReminderRule.self, from: JSONEncoder().encode(rule)), rule)
        XCTAssertThrowsError(try ReminderRule(identity: identity, anchor: anchor, scope: .thisOccurrence, format: .timed, enabled: true, triggers: []))
        let t = try ReminderTrigger.timed(hours: 0, minutes: 10)
        XCTAssertEqual(try ReminderRule(identity: identity, anchor: anchor, scope: .thisOccurrence, format: .timed, enabled: true, triggers: [t,t]).triggers.count, 1)
    }
    func testSeriesReplacementAndOffOverride() throws {
        let identity = ReminderIdentity(calendarID: "c", localItemID: "i", confirmedSeriesKey: "s")
        func rule(_ day: Int, _ scope: ReminderScope, _ enabled: Bool = true) throws -> ReminderRule {
            try ReminderRule(identity: identity, anchor: .timed(date("2024-03-0\(day)T10:00:00Z")), scope: scope, format: .timed, enabled: enabled, triggers: enabled ? [.timed(hours: 0, minutes: 10)] : [])
        }
        var rules = ReminderRules()
        try rules.replace(with: rule(1, .thisAndFuture))
        try rules.replace(with: rule(3, .thisAndFuture))
        let off = try rule(4, .thisOccurrence, false)
        try rules.replace(with: off)
        try rules.replace(with: rule(2, .thisAndFuture, false))
        XCTAssertEqual(rules.rules.count, 3)
        XCTAssertEqual(rules.resolve(identity: identity, anchor: off.anchor)?.id, off.id)
        rules.removeOverride(identity: identity, anchor: off.anchor)
        XCTAssertEqual(rules.resolve(identity: identity, anchor: off.anchor)?.anchor, try rule(2, .thisAndFuture).anchor)
        XCTAssertTrue(rules.resolve(identity: identity, anchor: try rule(1, .thisOccurrence).anchor)!.enabled)
    }
    func testCalculationDSTAndFormatChange() throws {
        let la = CalendarContext(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        let e = event(start: "2024-03-10T08:00:00Z", end: "2024-03-12T07:00:00Z", allDay: true)
        let identity = ReminderIdentity(calendarID: "c", localItemID: "i")
        let rule = try ReminderRule(identity: identity, anchor: .civil(CivilDate(year: 2024, month: 3, day: 10)), scope: .thisOccurrence, format: .allDay, enabled: true, triggers: [.allDay(daysBefore: 0, hour: 2, minute: 30)])
        XCTAssertEqual(ReminderCalculator.calculate(rule: rule, event: e, now: date("2024-03-01T00:00:00Z"), context: la), .scheduled([date("2024-03-10T10:00:00Z")]))
        XCTAssertEqual(ReminderCalculator.calculate(rule: rule, event: e, now: date("2024-03-10T10:00:00Z"), context: la), .scheduled([]))
        XCTAssertEqual(ReminderCalculator.calculate(rule: rule, event: event(), now: Date(), context: la), .needsFormatConfirmation)
    }
}

extension PlanningTests {
    func testOriginalAnchorKeepsMovedOccurrencesDistinctAndMissingRecurringAnchorUnsafe() throws {
        let start = date("2024-03-05T10:00:00Z")
        func occurrence(_ anchor: OccurrenceAnchor?) -> EventOccurrence {
            EventOccurrence(calendarID: "c", calendarName: "", color: .init(red: 0, green: 0, blue: 0), eventID: "e", title: "", start: start, end: start, isAllDay: false, localItemID: "local", externalID: "external", isRecurring: true, originalOccurrence: anchor, confirmedSeriesKey: "series")
        }
        let first = occurrence(.timed(date("2024-03-01T10:00:00Z")))
        let second = occurrence(.timed(date("2024-03-02T10:00:00Z")))
        XCTAssertEqual(EventSearch.unique([first, second, first]).count, 2)
        XCTAssertNil(occurrence(nil).reminderAnchor(context: context))
        XCTAssertEqual(event().reminderIdentity.localItemID, "e")
        XCTAssertEqual(first.reminderAnchor(context: context), first.originalOccurrence)
        let detached = ReminderIdentity(calendarID: "c", localItemID: "detached", confirmedSeriesKey: "series")
        let off = try ReminderRule(identity: first.reminderIdentity, anchor: first.originalOccurrence!, scope: .thisOccurrence, format: .timed, enabled: false, triggers: [])
        XCTAssertEqual(ReminderRules(rules: [off]).resolve(identity: detached, anchor: first.originalOccurrence!), off)
        XCTAssertNil(ReminderRules(rules: [off]).resolve(identity: detached, anchor: second.originalOccurrence!))
    }
    func testRepeatedWallTimeUsesFirstAndTimedUsesElapsedMinutes() throws {
        let la = CalendarContext(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        let identity = ReminderIdentity(calendarID: "c", localItemID: "i")
        let all = event(start: "2024-11-03T07:00:00Z", end: "2024-11-04T08:00:00Z", allDay: true)
        let rule = try ReminderRule(identity: identity, anchor: .civil(CivilDate(year: 2024, month: 11, day: 3)), scope: .thisOccurrence, format: .allDay, enabled: true, triggers: [.allDay(daysBefore: 0, hour: 1, minute: 30)])
        XCTAssertEqual(ReminderCalculator.calculate(rule: rule, event: all, now: date("2024-11-01T00:00:00Z"), context: la), .scheduled([date("2024-11-03T08:30:00Z")]))
        let timed = event(start: "2024-03-10T10:30:00Z", end: "2024-03-10T11:00:00Z")
        let timedRule = try ReminderRule(identity: identity, anchor: .timed(timed.start), scope: .thisOccurrence, format: .timed, enabled: true, triggers: [.timed(hours: 1, minutes: 0)])
        XCTAssertEqual(ReminderCalculator.calculate(rule: timedRule, event: timed, now: date("2024-03-01T00:00:00Z"), context: la), .scheduled([date("2024-03-10T09:30:00Z")]))
    }
    func testDefaultYearRangeAndAsuncionDayNormalization() throws {
        let range = try EventSearch.defaultInterval(now: date("2024-02-29T12:00:00Z"), context: context)
        XCTAssertEqual(range.start, date("2023-02-28T00:00:00Z"))
        XCTAssertEqual(range.end, date("2025-03-01T00:00:00Z"))
        let asuncion = CalendarContext(timeZone: TimeZone(identifier: "America/Asuncion")!)
        let bounds = try EventSearch.interval(startDate: date("2023-10-01T12:00:00Z"), endDate: date("2023-10-02T12:00:00Z"), context: asuncion)
        XCTAssertEqual(bounds.start, date("2023-10-01T04:00:00Z"))
        XCTAssertEqual(bounds.end, date("2023-10-03T03:00:00Z"))
        let all = event(start: "2023-10-01T04:00:00Z", end: "2023-10-03T03:00:00Z", allDay: true)
        let groups = AgendaIndex.groups(events: [all], interval: bounds, context: asuncion)
        XCTAssertEqual(groups.map(\.day), [bounds.start, date("2023-10-02T03:00:00Z")])
    }
    func testNonrecurringMoveRetainsRuleAndFormatChangeRequiresConfirmation() throws {
        let original = event()
        let rule = try ReminderDefaults().rule(identity: original.reminderIdentity, anchor: original.reminderAnchor(context: context)!, scope: .thisOccurrence, format: .timed)
        var rules = ReminderRules(rules: [rule])
        let moved = event(start: "2024-03-05T10:00:00Z", end: "2024-03-05T11:00:00Z")
        XCTAssertEqual(rules.resolve(event: moved, context: context), rule)
        XCTAssertEqual(ReminderCalculator.calculate(rule: rule, event: moved, now: date("2024-03-01T00:00:00Z"), context: context), .scheduled([date("2024-03-05T09:00:00Z"), date("2024-03-05T09:50:00Z")]))
        let changed = event(start: "2024-03-05T00:00:00Z", end: "2024-03-06T00:00:00Z", allDay: true)
        XCTAssertEqual(rules.resolve(event: changed, context: context), rule)
        XCTAssertEqual(ReminderCalculator.calculate(rule: rule, event: changed, now: date("2024-03-01T00:00:00Z"), context: context), .needsFormatConfirmation)
        let confirmed = try ReminderRule(id: rule.id, identity: rule.identity, anchor: rule.anchor, scope: rule.scope, format: .allDay, enabled: true, triggers: [.allDay(daysBefore: 0, hour: 9, minute: 0)])
        try rules.replace(with: confirmed)
        XCTAssertEqual(rules.rules.count, 1)
        XCTAssertEqual(ReminderCalculator.calculate(rule: confirmed, event: changed, now: date("2024-03-01T00:00:00Z"), context: context), .scheduled([date("2024-03-05T09:00:00Z")]))
        rules.removeOverride(event: moved, context: context)
        XCTAssertTrue(rules.rules.isEmpty)
    }
    func testStoredInvalidTriggersAndRulesAreRejected() throws {
        let trigger = try ReminderTrigger.timed(hours: 0, minutes: 10)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trigger)) as! [String: Any]
        object["minutesBefore"] = -1
        XCTAssertThrowsError(try JSONDecoder().decode(ReminderTrigger.self, from: JSONSerialization.data(withJSONObject: object)))
        let identity = ReminderIdentity(calendarID: "c", localItemID: "i")
        XCTAssertThrowsError(try ReminderRule(identity: identity, anchor: .timed(Date()), scope: .thisAndFuture, format: .timed, enabled: true, triggers: [trigger]))
        XCTAssertThrowsError(try ReminderRule(identity: identity, anchor: .civil(CivilDate(year: 2024, month: 2, day: 30)), scope: .thisOccurrence, format: .timed, enabled: true, triggers: [trigger]))
        XCTAssertThrowsError(try ReminderTrigger.allDay(daysBefore: Int.max, hour: 0, minute: 0))
        XCTAssertThrowsError(try ReminderTrigger.timed(hours: 1, minutes: 60))
    }
}
