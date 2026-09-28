import Foundation

public enum CalendarValueError: Error, Equatable { case invalidRange, invalidTrigger, emptyTriggers, formatMismatch, unconfirmedSeries, invalidAnchor }

public enum EventSearch {
    public static func interval(startDate: Date, endDate: Date, context: CalendarContext) throws -> DateInterval {
        let start = context.calendar.startOfDay(for: startDate)
        let last = context.calendar.startOfDay(for: endDate)
        guard start <= last, let next = context.calendar.date(byAdding: .day, value: 1, to: last) else { throw CalendarValueError.invalidRange }
        return DateInterval(start: start, end: context.calendar.startOfDay(for: next))
    }
    public static func defaultInterval(now: Date, context: CalendarContext) throws -> DateInterval {
        guard let start = context.calendar.date(byAdding: .year, value: -1, to: now), let end = context.calendar.date(byAdding: .year, value: 1, to: now) else { throw CalendarValueError.invalidRange }
        return try interval(startDate: start, endDate: end, context: context)
    }
    public static func unique(_ events: [EventOccurrence]) -> [EventOccurrence] {
        var seen = Set<EventOccurrence.ID>()
        return events.filter { seen.insert($0.id).inserted }
    }
    public static func overlaps(_ event: EventOccurrence, interval: DateInterval) -> Bool {
        if event.start == event.end { return event.start >= interval.start && event.start < interval.end }
        return event.end > event.start && event.start < interval.end && event.end > interval.start
    }
    public static func results(query: String, events: [EventOccurrence], selectedCalendarIDs: Set<String>, interval: DateInterval) -> [EventOccurrence] {
        func normalized(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        let phrase = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !phrase.isEmpty else { return [] }
        return unique(events).filter { selectedCalendarIDs.contains($0.calendarID) && overlaps($0, interval: interval) && normalized($0.title).contains(phrase) }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id < $1.id
        }
    }
}

public struct AgendaDay: Equatable, Sendable, Identifiable {
    public var id: Date { day }
    public let day: Date
    public let events: [EventOccurrence]
}
public enum AgendaIndex {
    public static func groups(events: [EventOccurrence], interval: DateInterval, context: CalendarContext) -> [AgendaDay] {
        let events = EventSearch.unique(events).filter { EventSearch.overlaps($0, interval: interval) }
        var day = context.calendar.startOfDay(for: interval.start)
        var groups: [AgendaDay] = []
        while day < interval.end {
            let matches = EventIndex.events(on: day, in: events, context: context)
            if !matches.isEmpty { groups.append(AgendaDay(day: day, events: matches)) }
            guard let next = context.calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let normalized = context.calendar.startOfDay(for: next)
            guard normalized > day else { break }
            day = normalized
        }
        return groups
    }
}
