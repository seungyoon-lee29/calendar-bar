import XCTest
import CalendarCore
@testable import CalendarAccess
import CalendarNotifications
@testable import CalendarUI

final class ReminderEditorTests: XCTestCase {
    func testDraftDefaultsAreCopiedAndValidationIsStrict() throws {
        var defaults = ReminderDefaults()
        var draft = ReminderDraft(event: sample(), existing: nil, defaults: defaults, context: context)
        defaults.timed = [try .timed(hours: 2, minutes: 0)]
        XCTAssertEqual(try draft.triggers().map(\.minutesBefore), [60, 10])
        draft.apply(defaults)
        XCTAssertEqual(try draft.triggers().map(\.minutesBefore), [120])
        draft.rows[0].minute = "60"
        XCTAssertThrowsError(try draft.triggers())
        draft.rows.removeAll()
        XCTAssertThrowsError(try draft.rule(enabled: true))
        XCTAssertFalse(try draft.rule(enabled: false).enabled)
    }
    func testMovedOccurrenceKeepsOriginalAnchorAndID() throws {
        let original = Date(timeIntervalSince1970: 10000)
        let event = sample()
        let existing = try ReminderRule(identity: event.reminderIdentity, anchor: .timed(original), scope: .thisOccurrence, format: .timed, enabled: true, triggers: ReminderDefaults().timed)
        let draft = ReminderDraft(event: event, existing: existing, defaults: ReminderDefaults(), context: context)
        let saved = try draft.rule(enabled: true)
        XCTAssertEqual(saved.anchor, .timed(original))
        XCTAssertEqual(saved.id, existing.id)
    }
    func testInheritedRuleDoesNotMoveSeriesAnchorWhenCreatingOverride() throws {
        let event = sample(recurring: true)
        let parent = try ReminderRule(identity: event.reminderIdentity, anchor: .timed(Date(timeIntervalSince1970: 1)), scope: .thisAndFuture, format: .timed, enabled: true, triggers: ReminderDefaults().timed)
        var draft = ReminderDraft(event: event, existing: parent, defaults: ReminderDefaults(), context: context)
        draft.scope = .thisOccurrence
        let off = try draft.rule(enabled: false)
        XCTAssertEqual(off.anchor, event.originalOccurrence)
        XCTAssertNotEqual(off.id, parent.id)
        var rules = ReminderRules(rules: [parent, off])
        try rules.replace(with: parent)
        XCTAssertFalse(try XCTUnwrap(rules.resolve(event: event, context: context)).enabled)
        rules.removeOverride(identity: event.reminderIdentity, anchor: off.anchor)
        XCTAssertTrue(try XCTUnwrap(rules.resolve(event: event, context: context)).enabled)
    }
    func testFormatConversionRequiresConfirmationAndKeepsAnchor() throws {
        let event = sample(allDay: true)
        let existing = try ReminderRule(identity: event.reminderIdentity, anchor: .timed(Date(timeIntervalSince1970: 1)), scope: .thisOccurrence, format: .timed, enabled: true, triggers: ReminderDefaults().timed)
        var draft = ReminderDraft(event: event, existing: existing, defaults: ReminderDefaults(), context: context)
        XCTAssertTrue(draft.requiresFormatConfirmation)
        XCTAssertThrowsError(try draft.rule(enabled: true))
        draft.formatConfirmed = true
        XCTAssertEqual(try draft.rule(enabled: true).format, .allDay)
        XCTAssertEqual(try draft.rule(enabled: true).anchor, existing.anchor)
    }
    func testAdapterFormatConversionsPreserveSavedIDAndAnchor() throws {
        let original = Date(timeIntervalSince1970: 2_000_000_000)
        for allDay in [true, false] {
            let anchors = EventKitBackend.occurrenceAnchors(originalDate: original, isAllDay: allDay, context: context)
            let event = EventOccurrence(calendarID: "cal", calendarName: "", color: .init(red: 0, green: 0, blue: 0), eventID: "event", title: "", start: original, end: original.addingTimeInterval(3600), isAllDay: allDay, isRecurring: true, originalOccurrence: anchors.first, confirmedSeriesKey: "series", originalOccurrenceAlternatives: Array(anchors.dropFirst()))
            let format: ReminderFormat = allDay ? .timed : .allDay
            let oldAnchor = EventKitBackend.occurrenceAnchors(originalDate: original, isAllDay: !allDay, context: context)[0]
            let old = try ReminderRule(identity: event.reminderIdentity, anchor: oldAnchor, scope: .thisOccurrence, format: format, enabled: false, triggers: [])
            var rules = ReminderRules(rules: [old])
            var draft = ReminderDraft(event: event, existing: rules.resolve(event: event, context: context), defaults: ReminderDefaults(), context: context)
            XCTAssertTrue(draft.requiresFormatConfirmation)
            XCTAssertThrowsError(try draft.rule(enabled: true))
            draft.formatConfirmed = true
            let saved = try draft.rule(enabled: true)
            XCTAssertEqual(saved.id, old.id); XCTAssertEqual(saved.anchor, old.anchor)
            try rules.replace(with: saved)
            XCTAssertEqual(rules.rules.count, 1)
        }
    }
    func testEarlierConvertedFutureRuleReplacesLaterBoundaryAndPreservesOff() throws {
        let original = Date(timeIntervalSince1970: 2_000_000_000)
        for allDay in [true, false] {
            func event(_ offset: TimeInterval, allDay: Bool) -> EventOccurrence {
                let date = original.addingTimeInterval(offset)
                let anchors = EventKitBackend.occurrenceAnchors(originalDate: date, isAllDay: allDay, context: context)
                return EventOccurrence(calendarID: "cal", calendarName: "", color: .init(red: 0, green: 0, blue: 0), eventID: "series", title: "", start: date, end: date.addingTimeInterval(3600), isAllDay: allDay, isRecurring: true, originalOccurrence: anchors.first, confirmedSeriesKey: "series", originalOccurrenceAlternatives: Array(anchors.dropFirst()))
            }
            let a = event(0, allDay: allDay), b = event(86400, allDay: !allDay), c = event(172800, allDay: !allDay)
            let oldFormat: ReminderFormat = allDay ? .timed : .allDay
            let old = try ReminderRule(identity: b.reminderIdentity, anchor: b.originalOccurrence!, scope: .thisAndFuture, format: oldFormat, enabled: true, triggers: allDay ? ReminderDefaults().timed : ReminderDefaults().allDay)
            let off = try ReminderRule(identity: c.reminderIdentity, anchor: c.originalOccurrence!, scope: .thisOccurrence, format: oldFormat, enabled: false, triggers: [])
            var rules = ReminderRules(rules: [old, off])
            XCTAssertNil(rules.resolve(event: a, context: context))
            let mismatched = try ReminderRule(identity: a.reminderIdentity, anchor: a.originalOccurrence!, scope: .thisAndFuture, format: allDay ? .allDay : .timed, enabled: true, triggers: allDay ? ReminderDefaults().allDay : ReminderDefaults().timed)
            XCTAssertThrowsError(try rules.replace(with: mismatched))
            XCTAssertEqual(rules.rules, [old, off])
            let mixed = try JSONDecoder().decode(ReminderRules.self, from: JSONEncoder().encode(ReminderRules(rules: [old, mismatched, off])))
            XCTAssertTrue(mixed.needsIdentityConfirmation(event: b))
            XCTAssertNil(mixed.resolve(event: b, context: context))
            XCTAssertNil(mixed.futureEditingAnchor(event: a, context: context))
            XCTAssertEqual(mixed.resolve(event: c, context: context)?.id, off.id)
            var draft = ReminderDraft(event: a, existing: nil, defaults: ReminderDefaults(), context: context, rules: rules)
            draft.scope = .thisAndFuture
            let replacement = try draft.rule(enabled: true)
            try rules.replace(with: replacement)
            XCTAssertEqual(rules.rules.filter { $0.scope == .thisAndFuture }.count, 1)
            XCTAssertEqual(rules.resolve(event: b, context: context)?.id, replacement.id)
            XCTAssertEqual(rules.resolve(event: c, context: context)?.id, off.id)
            XCTAssertFalse(rules.rules.contains { $0.id == old.id })

            if !allDay { // A needs the series' saved civil representation, which is ambiguous.
                var ambiguous = a
                ambiguous.ambiguousOriginalOccurrences.insert(.civil(CivilDate(date: original, context: context)))
                var blocked = ReminderDraft(event: ambiguous, existing: nil, defaults: ReminderDefaults(), context: context, rules: ReminderRules(rules: [old]))
                blocked.scope = .thisAndFuture
                XCTAssertFalse(blocked.canUseFuture)
                XCTAssertNil(blocked.occurrenceAnchor)
                XCTAssertThrowsError(try blocked.rule(enabled: true))
            }
        }
    }
    private var context: CalendarContext { CalendarContext(timeZone: TimeZone(secondsFromGMT: 0)!) }
    private func sample(recurring: Bool = false, allDay: Bool = false) -> EventOccurrence {
        .init(calendarID: "qa", calendarName: "Sample", color: .init(red: 0, green: 0, blue: 1), eventID: "event", title: "Synthetic", start: Date(timeIntervalSince1970: 20000), end: Date(timeIntervalSince1970: 23000), isAllDay: allDay, isRecurring: recurring, originalOccurrence: recurring ? .timed(Date(timeIntervalSince1970: 20000)) : nil, confirmedSeriesKey: recurring ? "series" : nil)
    }
}
