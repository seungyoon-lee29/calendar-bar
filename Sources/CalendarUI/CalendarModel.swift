import Foundation
import Observation
import CalendarCore
import CalendarAccess

/// A release must cross both the distance and axis thresholds. No predicted velocity.
enum MonthSwipe {
    static func direction(x: Double, y: Double, threshold: Double = 40) -> Int? {
        guard abs(x) > threshold, abs(x) > abs(y) else { return nil }
        return x < 0 ? 1 : -1
    }
}

@Observable @MainActor final class CalendarModel {
    private(set) var calendar: CalendarState
    let access: CalendarAccessController
    var showingSettings = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    init(access: CalendarAccessController, now: Date = Date(), timeZone: TimeZone = .current) {
        self.access = access
        calendar = CalendarState(now: now, timeZone: timeZone)
    }
    func open(now: Date = Date(), timeZone: TimeZone = .current) {
        showingSettings = false
        calendar.refreshToday(at: now, timeZone: timeZone)
        calendar.open(at: now)
        refresh()
    }
    func dateChanged(_ now: Date, timeZone: TimeZone = .current) {
        calendar.refreshToday(at: now, timeZone: timeZone)
        refresh()
    }
    func select(_ date: Date) { calendar.select(date); refresh() }
    func moveMonth(_ amount: Int) { calendar.moveMonth(by: amount); refresh() }
    func refresh() {
        refreshTask?.cancel()
        // Read the range when this task runs, rather than capturing an obsolete range.
        refreshTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            await access.refresh(interval: calendar.grid.queryInterval)
        }
    }
    func waitForRefresh() async { await refreshTask?.value }
    func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.calendar = calendar.context.calendar
        formatter.timeZone = calendar.context.calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    var selectedEvents: [EventOccurrence] {
        EventIndex.events(on: calendar.selectedDate, in: access.events, context: calendar.context)
    }
    func timeLabel(_ event: EventOccurrence) -> String {
        if event.isAllDay { return event.start < calendar.selectedDate ? "종일 · 진행 중" : "종일" }
        if event.start < calendar.selectedDate { return "진행 중" }
        return formatted(event.start, "a h:mm")
    }
}
