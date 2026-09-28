import Foundation

public struct RGBAColor: Equatable, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct EventOccurrence: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable, Comparable {
        public let calendarID: String
        public let eventID: String
        public let start: Date
        public let originalOccurrence: OccurrenceAnchor?
        public static func < (lhs: ID, rhs: ID) -> Bool {
            if lhs.calendarID != rhs.calendarID { return lhs.calendarID < rhs.calendarID }
            if lhs.eventID != rhs.eventID { return lhs.eventID < rhs.eventID }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            switch (lhs.originalOccurrence, rhs.originalOccurrence) {
            case (nil, .some): return true
            case let (.some(a), .some(b)): return a.sortsBefore(b)
            default: return false
            }
        }
    }
    public var id: ID { ID(calendarID: calendarID, eventID: eventID, start: start, originalOccurrence: originalOccurrenceAlternatives.first(where: { if case .timed = $0 { return true }; return false }) ?? originalOccurrence) }
    /// Separate from the display row ID; a backend must confirm remapping after sync.
    public var reminderIdentity: ReminderIdentity {
        ReminderIdentity(calendarID: calendarID, localItemID: localItemID, externalID: externalID, confirmedSeriesKey: confirmedSeriesKey)
    }
    public func reminderAnchor(context: CalendarContext) -> OccurrenceAnchor? {
        if let originalOccurrence { return originalOccurrence }
        guard !isRecurring else { return nil }
        return isAllDay ? .civil(CivilDate(date: start, context: context)) : .timed(start)
    }
    public let calendarID: String
    public let calendarName: String
    public let color: RGBAColor
    public let eventID: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let localItemID: String
    public let externalID: String?
    public let isRecurring: Bool
    public let originalOccurrence: OccurrenceAnchor?
    public let confirmedSeriesKey: String?
    /// Both representations of EventKit's original recurrence date, independent of
    /// the occurrence's current display format. These values are never persisted.
    public let originalOccurrenceAlternatives: [OccurrenceAnchor]
    public var ambiguousOriginalOccurrences: Set<OccurrenceAnchor> = []

    public func originalAnchor(matching anchor: OccurrenceAnchor) -> OccurrenceAnchor? {
        ([originalOccurrence].compactMap { $0 } + originalOccurrenceAlternatives).first {
            switch ($0, anchor) {
            case (.timed, .timed), (.civil, .civil): return true
            default: return false
            }
        }
    }
    public func matchesOriginalAnchor(_ anchor: OccurrenceAnchor) -> Bool {
        !ambiguousOriginalOccurrences.contains(anchor) && originalAnchor(matching: anchor) == anchor
    }
    /// Mark collisions before resolving rules. Exact timed evidence remains usable
    /// even when a civil date cannot identify one occurrence within a series.
    public static func markingAmbiguousOriginalDates(_ events: [Self]) -> [Self] {
        events.map { event in
            var result = event
            for anchor in [event.originalOccurrence].compactMap({ $0 }) + event.originalOccurrenceAlternatives {
                guard case .civil = anchor else { continue }
                if events.contains(where: { other in
                    other.id != event.id && other.reminderIdentity.matchesOccurrenceItem(event.reminderIdentity)
                        && other.originalAnchor(matching: anchor) == anchor
                }) { result.ambiguousOriginalOccurrences.insert(anchor) }
            }
            return result
        }
    }

    public init(calendarID: String, calendarName: String, color: RGBAColor, eventID: String, title: String?, start: Date, end: Date, isAllDay: Bool, localItemID: String? = nil, externalID: String? = nil, isRecurring: Bool = false, originalOccurrence: OccurrenceAnchor? = nil, confirmedSeriesKey: String? = nil, originalOccurrenceAlternatives: [OccurrenceAnchor] = []) {
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.color = color
        self.eventID = eventID
        self.title = title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "(제목 없음)"
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.localItemID = localItemID ?? eventID
        self.externalID = externalID
        self.isRecurring = isRecurring
        self.originalOccurrence = originalOccurrence
        self.confirmedSeriesKey = confirmedSeriesKey
        self.originalOccurrenceAlternatives = originalOccurrenceAlternatives
    }
}

public enum EventIndex {
    public static func events(on day: Date, in events: [EventOccurrence], context: CalendarContext) -> [EventOccurrence] {
        let interval = context.calendar.dateInterval(of: .day, for: day)!
        return events.filter { event in
            if event.start == event.end { return event.start >= interval.start && event.start < interval.end }
            return event.end > event.start && event.start < interval.end && event.end > interval.start
        }.sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }
    }

    /// One dot per calendar. Different calendars may intentionally share a color.
    public static func colors(on day: Date, in events: [EventOccurrence], context: CalendarContext) -> [RGBAColor] {
        var seen = Set<String>()
        return self.events(on: day, in: events, context: context).compactMap { event in
            seen.insert(event.calendarID).inserted ? event.color : nil
        }
    }
}
