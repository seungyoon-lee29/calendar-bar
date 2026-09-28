import Foundation
import CalendarCore

public enum CalendarQueryChannel: String, CaseIterable, Hashable, Sendable { case month, search, agenda, reminders }
public enum CalendarAccessChange: Sendable { case selection, permission, eventStore, wake }
public struct CalendarQuerySnapshot: Equatable, Sendable {
    public let interval: DateInterval?
    public let generation: Int
    public let state: CalendarViewState
    public let events: [EventOccurrence]
}
public enum CalendarEventResolution: Equatable, Sendable {
    case found(EventOccurrence), missing, needsConfirmation, outsideSelectedScope, connectionRequired, failed, outsideQuery
}
public enum CalendarQueryError: Error { case invalidRange, permissionRequired }

/// EventKit limits predicates to four years. Smaller chunks also bound individual reads.
public enum CalendarRangeQuery {
    private struct OccurrenceKey: Hashable {
        let calendarID: String
        let itemID: String
        let anchor: OccurrenceAnchor?
        let fallbackID: EventOccurrence.ID?
        init(_ event: EventOccurrence) {
            calendarID = event.calendarID
            itemID = event.confirmedSeriesKey ?? event.localItemID
            anchor = event.originalOccurrence
            fallbackID = anchor == nil ? event.id : nil
        }
    }
    static let chunkDuration: TimeInterval = 180 * 86_400
    public static func isValid(_ interval: DateInterval) -> Bool {
        interval.start.timeIntervalSinceReferenceDate.isFinite && interval.end.timeIntervalSinceReferenceDate.isFinite && interval.duration.isFinite && interval.duration > 0
    }
    public static func fetch(backend: any CalendarBackend, interval: DateInterval, calendarIDs: Set<String>) async throws -> [EventOccurrence] {
        guard isValid(interval) else { throw CalendarQueryError.invalidRange }
        guard !calendarIDs.isEmpty else { return [] }
        var cursor = interval.start
        var result: [OccurrenceKey: EventOccurrence] = [:]
        while cursor < interval.end {
            try Task.checkCancellation()
            guard await backend.permission() == .authorized else { throw CalendarQueryError.permissionRequired }
            let end = min(cursor.addingTimeInterval(chunkDuration), interval.end)
            guard end > cursor else { throw CalendarQueryError.invalidRange }
            let values = try await backend.events(interval: DateInterval(start: cursor, end: end), calendarIDs: calendarIDs)
            for event in values where calendarIDs.contains(event.calendarID) && event.end >= event.start && event.start < interval.end && (event.end > interval.start || event.start == event.end && event.start >= interval.start) {
                result[OccurrenceKey(event)] = event
            }
            cursor = end
        }
        return result.values.sorted { $0.id < $1.id }
    }
}
public extension CalendarBackend {
    /// Default adapters cannot prove deletion outside their query coverage.
    func resolve(identity: ReminderIdentity, anchor: OccurrenceAnchor?, isRecurring: Bool, searchInterval: DateInterval?, calendarIDs: Set<String>) async throws -> CalendarEventResolution {
        guard CalendarResolution.isValid(anchor: anchor, searchInterval: searchInterval) else { return .failed }
        guard calendarIDs.contains(identity.calendarID) else { return .outsideSelectedScope }
        guard let interval = searchInterval else { return .outsideQuery }
        let events = try await CalendarRangeQuery.fetch(backend: self, interval: interval, calendarIDs: [identity.calendarID])
        return CalendarResolution.match(events, identity: identity, anchor: anchor, isRecurring: isRecurring, absence: .outsideQuery)
    }
}
enum CalendarResolution {
    static func isValid(anchor: OccurrenceAnchor?, searchInterval: DateInterval?) -> Bool {
        if let searchInterval, !CalendarRangeQuery.isValid(searchInterval) { return false }
        switch anchor {
        case nil: return true
        case .timed(let date): return date.timeIntervalSinceReferenceDate.isFinite
        case .civil(let civil):
            let context = CalendarContext(timeZone: .current)
            guard let date = context.calendar.date(from: DateComponents(year: civil.year, month: civil.month, day: civil.day)), date.timeIntervalSinceReferenceDate.isFinite else { return false }
            return CivilDate(date: date, context: context) == civil
        }
    }
    static func match(_ events: [EventOccurrence], identity: ReminderIdentity, anchor: OccurrenceAnchor?, isRecurring: Bool, absence: CalendarEventResolution) -> CalendarEventResolution {
        let scoped = events.filter { $0.calendarID == identity.calendarID }
        let candidates = scoped.filter { event in
            guard identity.matchesOccurrenceItem(event.reminderIdentity) else { return false }
            return !isRecurring || anchor != nil && event.originalOccurrence == anchor
        }
        if candidates.count == 1 { return .found(candidates[0]) }
        if candidates.count > 1 { return .needsConfirmation }
        if let external = identity.externalID, scoped.contains(where: { $0.externalID == external }) { return .needsConfirmation }
        return absence
    }
}
