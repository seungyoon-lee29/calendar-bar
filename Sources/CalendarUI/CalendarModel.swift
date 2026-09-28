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

enum CalendarTab: String, CaseIterable { case calendar = "달력", upcoming = "예정 일정" }

@Observable @MainActor final class CalendarModel {
    private(set) var tab: CalendarTab = .calendar
    var searchText = "" { didSet { scheduleSearch() } }
    var searchStart: Date { didSet { scheduleSearch() } }
    var searchEnd: Date { didSet { scheduleSearch() } }
    private(set) var agendaDays = 30
    private(set) var searchPending = false
    private(set) var highlightedEventID: EventOccurrence.ID?
    var selectedReminderEvent: EventOccurrence?
    private(set) var navigationMessage: String?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var agendaTask: Task<Void, Never>?
    @ObservationIgnored private var searchRevision = 0
    @ObservationIgnored private var navigationRevision = 0
    private(set) var calendar: CalendarState
    let access: CalendarAccessController
    var showingSettings = false
    private(set) var presentationID = UUID()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    init(access: CalendarAccessController, now: Date = Date(), timeZone: TimeZone = .current) {
        self.access = access
        let initial = CalendarState(now: now, timeZone: timeZone)
        calendar = initial
        searchStart = initial.context.calendar.date(byAdding: .year, value: -1, to: now)!
        searchEnd = initial.context.calendar.date(byAdding: .year, value: 1, to: now)!
    }
    func open(now: Date = Date(), timeZone: TimeZone = .current) {
        showingSettings = false
        tab = .calendar
        searchText = ""
        agendaDays = 30
        agendaTask?.cancel()
        highlightedEventID = nil
        selectedReminderEvent = nil
        navigationMessage = nil
        navigationRevision += 1
        presentationID = UUID()
        calendar.refreshToday(at: now, timeZone: timeZone)
        calendar.open(at: now)
        searchStart = calendar.context.calendar.date(byAdding: .year, value: -1, to: now)!
        searchEnd = calendar.context.calendar.date(byAdding: .year, value: 1, to: now)!
        refresh()
    }
    func dateChanged(_ now: Date, timeZone: TimeZone = .current) {
        calendar.refreshToday(at: now, timeZone: timeZone)
        scheduleSearch()
        if tab == .upcoming { refreshAgenda() }
        refresh()
    }
    func select(_ date: Date) { invalidateNavigation(); calendar.select(date); refresh() }
    func moveMonth(_ amount: Int) { invalidateNavigation(); calendar.moveMonth(by: amount); refresh() }
    func refresh() {
        refreshTask?.cancel()
        // Read the range when this task runs, rather than capturing an obsolete range.
        refreshTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            await access.refresh(interval: calendar.grid.queryInterval)
        }
    }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var searchInterval: DateInterval? { try? EventSearch.interval(startDate: searchStart, endDate: searchEnd, context: calendar.context) }
    var searchState: CalendarViewState {
        if searchPending { return .loading }
        let snapshot = access.snapshot(for: .search)
        return snapshot.interval == searchInterval ? snapshot.state : .loading
    }
    var searchResults: [EventOccurrence] {
        guard searchState == .loaded, let interval = searchInterval else { return [] }
        return EventSearch.results(query: searchText, events: access.snapshot(for: .search).events, selectedCalendarIDs: access.effectiveSelectedCalendarIDs, interval: interval)
    }
    var agendaInterval: DateInterval {
        let start = calendar.context.calendar.startOfDay(for: calendar.today)
        return DateInterval(start: start, end: calendar.context.calendar.date(byAdding: .day, value: agendaDays, to: start)!)
    }
    var agendaState: CalendarViewState {
        let snapshot = access.snapshot(for: .agenda)
        return snapshot.interval == agendaInterval ? snapshot.state : .loading
    }
    var agendaGroups: [AgendaDay] {
        guard agendaState == .loaded else { return [] }
        return AgendaIndex.groups(events: access.snapshot(for: .agenda).events, interval: agendaInterval, context: calendar.context)
    }
    func setTab(_ value: CalendarTab) {
        invalidateNavigation()
        tab = value
        if value == .upcoming { refreshAgenda() }
    }
    private func invalidateNavigation() {
        presentationID = UUID()
        navigationRevision += 1
        highlightedEventID = nil
        navigationMessage = nil
    }
    func scheduleSearch() {
        presentationID = UUID()
        searchTask?.cancel()
        searchRevision += 1
        navigationRevision += 1
        navigationMessage = nil
        guard isSearching, let interval = searchInterval else { searchPending = false; return }
        searchPending = true
        let revision = searchRevision
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, revision == searchRevision, !Task.isCancelled else { return }
            await access.refresh(channel: .search, interval: interval)
            guard revision == searchRevision, !Task.isCancelled else { return }
            searchPending = false
        }
    }
    func refreshAgenda() {
        agendaTask?.cancel()
        let interval = agendaInterval
        agendaTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await access.refresh(channel: .agenda, interval: interval)
        }
    }
    func loadMoreAgenda() { agendaDays += 30; refreshAgenda() }
    func waitForSearch() async { await searchTask?.value }
    func waitForAgenda() async { await agendaTask?.value }
    func activate(_ event: EventOccurrence, interval: DateInterval?) async {
        navigationRevision += 1
        let revision = navigationRevision
        let result = await access.resolve(identity: event.reminderIdentity, anchor: event.reminderAnchor(context: calendar.context), isRecurring: event.isRecurring, searchInterval: interval)
        guard revision == navigationRevision else { return }
        switch result {
        case .found(let current): goToResolvedOccurrence(current)
        case .connectionRequired: navigationMessage = "캘린더 접근이 허용되지 않았습니다."
        case .failed: navigationMessage = "일정을 확인하지 못했습니다. 다시 시도해 주세요."
        default:
            navigationMessage = "더 이상 표시할 수 없는 일정입니다."
            if isSearching { // Refresh without replacing the resolution message.
                let message = navigationMessage
                scheduleSearch()
                navigationMessage = message
            } else if tab == .upcoming { refreshAgenda() } else { refresh() }
        }
    }
    func goToResolvedOccurrence(_ event: EventOccurrence) {
        guard access.permission == .authorized, access.selectedCalendarIDs.contains(event.calendarID) else { return }
        searchText = ""
        tab = .calendar
        showingSettings = false
        select(event.start)
        highlightedEventID = event.id
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
