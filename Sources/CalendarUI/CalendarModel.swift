import Foundation
import Observation
import CalendarCore
import CalendarAccess
import CalendarNotifications

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
    private(set) var selectedReminderEvent: EventOccurrence?
    private(set) var isResolvingReminder = false
    var reminderDraft: ReminderDraft?
    var reminderError: String?
    private(set) var reminderBusy = false
    let reminders: ReminderCoordinator?
    @ObservationIgnored private var reminderEditingID = UUID()
    @ObservationIgnored private var privacyTask: Task<Void, Never>?
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
    init(access: CalendarAccessController, now: Date = Date(), timeZone: TimeZone = .current, reminders: ReminderCoordinator? = nil) {
        self.access = access
        self.reminders = reminders
        let initial = CalendarState(now: now, timeZone: timeZone)
        calendar = initial
        searchStart = initial.context.calendar.date(byAdding: .year, value: -1, to: now)!
        searchEnd = initial.context.calendar.date(byAdding: .year, value: 1, to: now)!
        let changes = access.changes()
        privacyTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                self?.clearInaccessibleEditor()
            }
        }
    }
    func open(now: Date = Date(), timeZone: TimeZone = .current) {
        showingSettings = false
        tab = .calendar
        searchText = ""
        agendaDays = 30
        agendaTask?.cancel()
        highlightedEventID = nil
        cancelReminder()
        navigationMessage = nil
        isResolvingReminder = false
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
        isResolvingReminder = false
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
    deinit { privacyTask?.cancel() }
    var canDisplayReminder: Bool {
        guard let event = selectedReminderEvent else { return false }
        return access.permission == .authorized && access.effectiveSelectedCalendarIDs.contains(event.calendarID)
    }
    func clearInaccessibleEditor() {
        if !canDisplayReminder { cancelReminder() }
    }
    func editReminder(_ event: EventOccurrence) {
        guard access.permission == .authorized, access.effectiveSelectedCalendarIDs.contains(event.calendarID), let reminders else { return }
        presentationID = UUID()
        reminderEditingID = UUID()
        selectedReminderEvent = event
        reminderError = nil
        reminderDraft = ReminderDraft(event: event, existing: reminders.settings.rules.resolve(event: event, context: calendar.context), defaults: reminders.settings.defaults, context: calendar.context)
    }
    func cancelReminder() { reminderEditingID = UUID(); selectedReminderEvent = nil; reminderDraft = nil; reminderError = nil }
    func saveReminder(enabled: Bool) async {
        guard !reminderBusy, let reminders, let draft = reminderDraft, canDisplayReminder else { clearInaccessibleEditor(); return }
        let editingID = reminderEditingID
        reminderBusy = true
        defer { reminderBusy = false }
        do {
            let result = await access.resolve(identity: draft.event.reminderIdentity, anchor: draft.occurrenceAnchor, isRecurring: draft.event.isRecurring, searchInterval: DateInterval(start: draft.event.start.addingTimeInterval(-86400), end: draft.event.start.addingTimeInterval(366 * 86400)))
            guard editingID == reminderEditingID else { return }
            guard canDisplayReminder else { clearInaccessibleEditor(); return }
            guard case .found(let current) = result else {
                reminderError = "현재 일정을 확인하지 못했습니다. 캘린더를 새로고침한 뒤 다시 시도해 주세요."
                return
            }
            guard current.isAllDay == draft.event.isAllDay else {
                editReminder(current)
                reminderError = "일정 형식이 변경되었습니다. 새 알림 시간을 확인한 뒤 다시 저장해 주세요."
                return
            }
            let rule = try draft.rule(enabled: enabled)
            try await reminders.save(rule: rule, event: current)
            guard editingID == reminderEditingID else { return }
            clearInaccessibleEditor()
            // Keep the editor open so actual delivery state and permission failures stay visible.
            if editingID == reminderEditingID && canDisplayReminder { editReminder(draft.event) }
        } catch { if editingID == reminderEditingID && canDisplayReminder { reminderError = "저장하지 못했습니다. 숫자와 알림 시간을 확인하고 다시 시도해 주세요." } }
    }
    func resumeInheritedReminder() async {
        guard !reminderBusy, let reminders, let draft = reminderDraft, let anchor = draft.occurrenceAnchor, canDisplayReminder else { return }
        let editingID = reminderEditingID
        reminderBusy = true
        defer { reminderBusy = false }
        do {
            try await reminders.removeOverride(identity: draft.event.reminderIdentity, anchor: anchor)
            if editingID == reminderEditingID && canDisplayReminder { editReminder(draft.event) }
        } catch { if editingID == reminderEditingID && canDisplayReminder { reminderError = "개별 설정을 해제하지 못했습니다. 다시 시도해 주세요." } }
    }
    func routeReminder(token: String) async {
        cancelReminder()
        navigationRevision += 1
        let revision = navigationRevision
        presentationID = UUID()
        showingSettings = false
        navigationMessage = "일정을 확인하는 중…"
        isResolvingReminder = true
        defer { if revision == navigationRevision { isResolvingReminder = false } }
        guard let link = reminders?.clickLink(token: token) else {
            navigationMessage = "이 알림의 일정을 확인할 수 없습니다. 캘린더에서 다시 찾아 주세요."
            return
        }
        let start: Date
        switch link.anchor {
        case .timed(let date): start = date
        case .civil(let civil): start = calendar.context.calendar.date(from: DateComponents(year: civil.year, month: civil.month, day: civil.day)) ?? calendar.today
        }
        let interval = DateInterval(start: start.addingTimeInterval(-86400), end: start.addingTimeInterval(366 * 86400))
        let result = await access.resolve(identity: link.identity, anchor: link.anchor, isRecurring: link.isRecurring, searchInterval: interval)
        guard revision == navigationRevision else { return }
        switch result {
        case .found(let event): goToResolvedOccurrence(event)
        case .connectionRequired: navigationMessage = "캘린더 접근을 허용한 뒤 다시 확인해 주세요."
        case .outsideSelectedScope: navigationMessage = "선택하지 않은 캘린더의 일정입니다. 설정에서 캘린더를 선택해 주세요."
        case .needsConfirmation: navigationMessage = "일정의 연결을 확인해야 합니다. 검색으로 다시 찾아 주세요."
        case .failed: navigationMessage = "일정을 확인하지 못했습니다. 다시 시도해 주세요."
        case .missing, .outsideQuery: navigationMessage = "현재 확인할 수 없는 일정입니다. 캘린더에서 다시 찾아 주세요."
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
