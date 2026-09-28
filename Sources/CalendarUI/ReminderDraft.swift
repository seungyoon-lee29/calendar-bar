import Foundation
import CalendarCore

struct ReminderTriggerDraft: Identifiable {
    let id = UUID()
    var hours = "0"
    var minute = "10"
    var days = "1"
    var wallHour = "21"
    init(_ trigger: ReminderTrigger? = nil) {
        if let trigger {
            hours = String(trigger.minutesBefore / 60)
            minute = String(trigger.format == .timed ? trigger.minutesBefore % 60 : trigger.minute)
            days = String(trigger.daysBefore)
            wallHour = String(trigger.hour)
        }
    }
    func trigger(format: ReminderFormat) throws -> ReminderTrigger {
        guard let minute = Int(minute) else { throw CalendarValueError.invalidTrigger }
        if format == .timed {
            guard let hours = Int(hours) else { throw CalendarValueError.invalidTrigger }
            return try .timed(hours: hours, minutes: minute)
        }
        guard let days = Int(days), let hour = Int(wallHour) else { throw CalendarValueError.invalidTrigger }
        return try .allDay(daysBefore: days, hour: hour, minute: minute)
    }
}
struct ReminderDraft {
    let event: EventOccurrence
    let existing: ReminderRule?
    private let individualAnchor: OccurrenceAnchor?
    private let futureAnchor: OccurrenceAnchor?
    var occurrenceAnchor: OccurrenceAnchor? { scope == .thisAndFuture ? futureAnchor : individualAnchor }
    let format: ReminderFormat
    var scope: ReminderScope = .thisOccurrence
    var rows: [ReminderTriggerDraft]
    var formatConfirmed = false
    var requiresFormatConfirmation: Bool { existing.map { $0.format != format } ?? false }
    var canUseFuture: Bool { event.isRecurring && event.confirmedSeriesKey != nil && futureAnchor != nil }
    init(event: EventOccurrence, existing: ReminderRule?, defaults: ReminderDefaults, context: CalendarContext, needsIdentityConfirmation: Bool = false, rules: ReminderRules? = nil) {
        self.event = event; self.existing = existing
        individualAnchor = needsIdentityConfirmation ? nil : (existing.flatMap { event.isRecurring ? event.originalAnchor(matching: $0.anchor) : $0.anchor } ?? event.reminderAnchor(context: context))
        let savedRules = rules ?? ReminderRules(rules: existing.map { [$0] } ?? [])
        futureAnchor = needsIdentityConfirmation ? nil : savedRules.futureEditingAnchor(event: event, context: context)
        let targetFormat: ReminderFormat = event.isAllDay ? .allDay : .timed
        format = targetFormat
        // Editing starts at this occurrence. A future change must be an explicit choice.
        let triggers = existing.flatMap { $0.format == targetFormat && !$0.triggers.isEmpty ? $0.triggers : nil }
            ?? (event.isAllDay ? defaults.allDay : defaults.timed)
        rows = triggers.map(ReminderTriggerDraft.init)
    }
    mutating func apply(_ defaults: ReminderDefaults) {
        rows = (format == .timed ? defaults.timed : defaults.allDay).map(ReminderTriggerDraft.init)
    }
    func triggers() throws -> [ReminderTrigger] { try rows.map { try $0.trigger(format: format) } }
    func rule(enabled: Bool) throws -> ReminderRule {
        guard !enabled || !requiresFormatConfirmation || formatConfirmed else { throw CalendarValueError.formatMismatch }
        guard let occurrenceAnchor else { throw CalendarValueError.invalidAnchor }
        let editsSameRule = existing.map { $0.scope == scope && (scope == .thisOccurrence || $0.anchor == occurrenceAnchor) } ?? false
        let anchor = editsSameRule ? existing!.anchor : occurrenceAnchor
        return try ReminderRule(id: editsSameRule ? existing!.id : UUID(), identity: event.reminderIdentity, anchor: anchor, scope: scope, format: format, enabled: enabled, triggers: enabled ? triggers() : [])
    }
}
