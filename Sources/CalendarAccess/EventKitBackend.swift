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
        guard permission() == .authorized, interval.duration > 0, !calendarIDs.isEmpty else { return [] }
        let selected = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        // Never pass nil/empty calendars to EventKit: nil means every calendar.
        guard !selected.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: selected)
        return store.events(matching: predicate).map { event in
            // EventKit supplies floating all-day boundaries in the system time zone;
            // preserve these civil-day boundaries, without converting through UTC.
            EventOccurrence(calendarID: event.calendar.calendarIdentifier,
                calendarName: event.calendar.title, color: Self.color(event.calendar.cgColor),
                eventID: event.eventIdentifier ?? event.calendarItemIdentifier,
                title: event.title, start: event.startDate, end: event.endDate, isAllDay: event.isAllDay)
        }
    }
    private static func color(_ color: CGColor?) -> RGBAColor {
        guard let color, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else {
            return RGBAColor(red: 0.5, green: 0.5, blue: 0.5)
        }
        return RGBAColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }
}
