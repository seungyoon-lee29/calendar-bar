import Foundation
import EventKit
import AppKit
import CalendarCore

/// EventKit objects never leave this actor. Only immutable Sendable values cross to the UI.
public actor EventKitBackend: CalendarBackend {
    private var eventStore: EKEventStore?
    public init() {}
    private var store: EKEventStore {
        if let eventStore { return eventStore }
        let created = EKEventStore()
        eventStore = created
        return created
    }
    public func permission() -> CalendarPermission {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .authorized
        case .denied, .writeOnly: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }
    public func requestAccess() async throws { _ = try await store.requestFullAccessToEvents() }
    public func calendars() throws -> [CalendarDescriptor] {
        guard permission() == .authorized else { return [] }
        return store.calendars(for: .event).map {
            CalendarDescriptor(id: $0.calendarIdentifier, name: $0.title, sourceName: $0.source.title, color: Self.color($0.cgColor))
        }.sorted { ($0.name, $0.sourceName, $0.id) < ($1.name, $1.sourceName, $1.id) }
    }
    public func events(interval: DateInterval, calendarIDs: Set<String>) throws -> [EventOccurrence] {
        guard permission() == .authorized else { throw CalendarQueryError.permissionRequired }
        guard CalendarRangeQuery.isValid(interval), interval.duration <= CalendarRangeQuery.chunkDuration else { throw CalendarQueryError.invalidRange }
        guard !calendarIDs.isEmpty else { return [] }
        let selected = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        // Never pass nil/empty calendars to EventKit: nil means every calendar.
        guard !selected.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: selected)
        return store.events(matching: predicate).map(convert)
    }
    private func convert(_ event: EKEvent) -> EventOccurrence {
        let recurring = event.hasRecurrenceRules || event.isDetached
        let original = recurring ? event.occurrenceDate : event.startDate
        let anchor: OccurrenceAnchor? = original.map { date in
            event.isAllDay ? .civil(CivilDate(date: date, context: CalendarContext(timeZone: .current))) : .timed(date)
        }
        // A local calendar item is the only confirmed series evidence. External IDs
        // are not unique, and a detached item may have its own local identifier.
        let master = event.isDetached ? store.calendarItem(withIdentifier: event.calendarItemIdentifier) as? EKEvent : event
        let series = recurring && master?.hasRecurrenceRules == true && master?.isDetached == false && master?.calendar.calendarIdentifier == event.calendar.calendarIdentifier ? event.calendarItemIdentifier : nil
        return EventOccurrence(calendarID: event.calendar.calendarIdentifier,
            calendarName: event.calendar.title, color: Self.color(event.calendar.cgColor),
            eventID: event.eventIdentifier ?? event.calendarItemIdentifier,
            title: event.title, start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
            localItemID: event.calendarItemIdentifier, externalID: event.calendarItemExternalIdentifier,
            isRecurring: recurring, originalOccurrence: anchor, confirmedSeriesKey: series)
    }
    public func resolve(identity: ReminderIdentity, anchor: OccurrenceAnchor?, isRecurring: Bool, searchInterval: DateInterval?, calendarIDs: Set<String>) async throws -> CalendarEventResolution {
        guard permission() == .authorized else { return .connectionRequired }
        guard calendarIDs.contains(identity.calendarID) else { return .outsideSelectedScope }
        let local = store.calendarItem(withIdentifier: identity.localItemID) as? EKEvent
        if let local, local.calendar.calendarIdentifier != identity.calendarID { return .outsideSelectedScope }
        // Direct local lookup handles nonrecurring moves at any date, including
        // dates beyond the scheduler's current horizon.
        if !isRecurring, let local, local.calendar.calendarIdentifier == identity.calendarID {
            guard !local.hasRecurrenceRules && !local.isDetached else { return .needsConfirmation }
            return .found(convert(local))
        }
        if !isRecurring {
            if let external = identity.externalID, store.calendarItems(withExternalIdentifier: external).contains(where: { $0.calendar.calendarIdentifier == identity.calendarID }) { return .needsConfirmation }
            return .missing
        }
        guard let anchor else { return .needsConfirmation }
        let date: Date
        switch anchor {
        case .timed(let value): date = value
        case .civil(let value):
            guard let value = CalendarContext(timeZone: .current).calendar.date(from: DateComponents(year: value.year, month: value.month, day: value.day)) else { return .failed }
            date = value
        }
        guard date.timeIntervalSinceReferenceDate.isFinite else { return .failed }
        // Query the requested occurrence, never return event(withIdentifier:)'s
        // first recurrence. A caller-provided interval expands the search for moves.
        let start = min(date.addingTimeInterval(-86_400), searchInterval?.start ?? date)
        let end = max(date.addingTimeInterval(2 * 86_400), searchInterval?.end ?? date)
        let interval = DateInterval(start: start, end: end)
        var values = try await CalendarRangeQuery.fetch(backend: self, interval: interval, calendarIDs: [identity.calendarID])
        if let local, local.calendar.calendarIdentifier == identity.calendarID {
            let value = convert(local)
            if value.originalOccurrence == anchor && !values.contains(where: { $0.id == value.id }) { values.append(value) }
        }
        // An exception can move beyond the queried interval; lack of a match is
        // not proof of deletion while its series still exists.
        let externalCandidate = identity.externalID.map { external in
            store.calendarItems(withExternalIdentifier: external).contains { $0.calendar.calendarIdentifier == identity.calendarID }
        } ?? false
        let absence: CalendarEventResolution = local != nil ? .outsideQuery : externalCandidate ? .needsConfirmation : .missing
        return CalendarResolution.match(values, identity: identity, anchor: anchor, isRecurring: true, absence: absence)
    }
    private static func color(_ color: CGColor?) -> RGBAColor {
        guard let color, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else {
            return RGBAColor(red: 0.5, green: 0.5, blue: 0.5)
        }
        return RGBAColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }
}
