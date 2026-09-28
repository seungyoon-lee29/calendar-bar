import AppKit
import SwiftUI
import CalendarCore
import CalendarAccess
import CalendarNotifications
import MenuBar
import ServiceManagement

@MainActor struct CalendarPopover: View {
    @Bindable var model: CalendarModel
    @ObservedObject var login: LoginItemController
    @State private var paging = MonthPagingState()
    @GestureState private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let pageWidth = 340.0
    var loginToggleBinding: Binding<Bool> {
        Binding(get: { login.state == .enabled }, set: { login.setEnabled($0) })
    }
    func cancelPendingLoginRegistration() { login.setEnabled(false) }
    var body: some View {
        VStack(spacing: 0) {
            if model.isResolvingReminder {
                VStack(spacing: 12) { ProgressView(); Text("일정을 확인하는 중…").font(.caption) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else if model.canDisplayReminder, let reminders = model.reminders { ReminderEditorView(model: model, reminders: reminders) }
            else if model.showingSettings { settings } else {
                searchHeader
                if let message = model.navigationMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
                }
                if model.isSearching { searchPage }
                else if model.tab == .upcoming { upcomingPage }
                else { calendarPage }
            }
        }
        .frame(width: 340, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { resetPaging() }
        .onChange(of: model.access.permission) { _, _ in model.clearInaccessibleEditor() }
        .onChange(of: model.access.calendars) { _, _ in model.clearInaccessibleEditor() }
        .onChange(of: model.access.selectedCalendarIDs) { _, _ in model.clearInaccessibleEditor() }
        .onChange(of: model.presentationID) { _, _ in resetPaging() }
        .onChange(of: model.calendar.displayedMonth) { _, _ in resetPaging() }
    }
    private var calendarPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Text(model.formatted(model.calendar.displayedMonth, "yyyy년 M월"))
                    .font(.system(size: 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("오늘") { model.open() }.font(.system(size: 11)).buttonStyle(.bordered)
                Button { settleMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("이전 달")
                Button { settleMonth(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("다음 달")
            }.buttonStyle(.plain).padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
            HStack(spacing: 0) {
                ForEach(Array(["일", "월", "화", "수", "목", "금", "토"].enumerated()), id: \.offset) { index, day in
                    Text(day).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(index == 0 ? .red.opacity(0.7) : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }.padding(.horizontal, 16).padding(.bottom, 8)
            monthPager.padding(.bottom, 14)
            Divider().padding(.horizontal, 20)
            HStack {
                Text(model.formatted(model.calendar.selectedDate, "M월 d일 EEEE")).font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.access.state == .loaded { Text("일정 \(model.selectedEvents.count)개").foregroundStyle(.secondary).font(.system(size: 11)) }
            }.padding(.horizontal, 20).padding(.top, 15).padding(.bottom, 10)
            agenda.frame(maxHeight: .infinity)
            Divider()
            HStack {
                Button { model.showingSettings = true; login.refresh() } label: { Image(systemName: "gearshape").font(.system(size: 14)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("설정")
                Spacer()
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
    private func pageState(_ amount: Int) -> CalendarState {
        var state = model.calendar
        if amount != 0 { state.moveMonth(by: amount) }
        return state
    }
    private func gridHeight(_ state: CalendarState) -> Double {
        Double(state.grid.days.count / 7) * 41 - 3
    }
    private var monthPager: some View {
        let currentHeight = gridHeight(model.calendar)
        let neighborHeight = gridHeight(pageState(paging.offset < 0 ? 1 : -1))
        let progress = min(1, abs(paging.offset) / pageWidth)
        return ZStack(alignment: .topLeading) {
            ForEach(-1...1, id: \.self) { amount in
                MonthGridPage(state: pageState(amount), events: model.access.events, onSelect: model.select)
                    .equatable()
                    .frame(width: pageWidth)
                    .offset(x: Double(amount) * pageWidth + paging.offset)
                    .allowsHitTesting(amount == 0 && !paging.isSettling)
                    .accessibilityHidden(amount != 0)
            }
        }
        .frame(width: pageWidth, height: currentHeight + (neighborHeight - currentHeight) * progress, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 8)
            .updating($isDragging) { _, active, _ in active = true }
            .onChanged { value in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    paging.drag(x: value.translation.width, y: value.translation.height, width: pageWidth)
                }
            }
            .onEnded { value in
                settleMonth(MonthSwipe.direction(x: value.translation.width, y: value.translation.height))
            })
        .onChange(of: isDragging) { _, active in
            if !active && !paging.isSettling && paging.offset != 0 { settleMonth(nil) }
        }
    }
    private func settleMonth(_ direction: Int?) {
        guard !paging.isSettling else { return }
        let presentation = model.presentationID
        var token: Int?
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24), completionCriteria: .removed) {
            token = paging.settle(direction: direction, width: pageWidth)
        } completion: {
            guard presentation == model.presentationID, let token else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                guard paging.finish(token) else { return }
                if let direction { model.moveMonth(direction) }
            }
        }
    }
    private func resetPaging() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { paging.reset() }
    }
    @ViewBuilder private var agenda: some View {
        switch model.access.state {
        case .loaded:
            if model.selectedEvents.isEmpty {
                VStack { Spacer(); Text("일정 없음").font(.system(size: 13)).foregroundStyle(.secondary); Spacer() }
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.selectedEvents) { event in
                            EventDisplayRow(event: event, time: model.timeLabel(event), highlighted: model.highlightedEventID == event.id, action: nil, reminder: { model.editReminder(event) }, delivery: model.reminders?.snapshot(for: event)).id(event.id)
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 12)
                }
                .onAppear { if let id = model.highlightedEventID { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: model.highlightedEventID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        case .loading: ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        default: accessMessage.padding(.horizontal, 20)
        }
    }
    private var accessMessage: some View { stateMessage(model.access.state, retry: model.refresh) }
    @ViewBuilder private func stateMessage(_ state: CalendarViewState, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            switch state {
            case .connectionRequired:
                if model.access.permission == .denied || model.access.permission == .restricted {
                    Text("캘린더 접근이 허용되지 않았습니다.")
                    Button("시스템 설정 열기") { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") }
                } else {
                    Text("캘린더를 연결해 일정을 확인하세요.")
                    Text("macOS는 전체 접근 권한을 요청합니다.\n이 앱은 일정을 읽기만 합니다.").font(.system(size: 10)).foregroundStyle(.secondary)
                    Button("캘린더 연결") { Task { await model.access.requestAccess() } }
                }
            case .noCalendars:
                Text("연결된 캘린더가 없습니다.")
                Text("인터넷 계정에서 Google 등을 추가하고\n캘린더 동기화를 켜 주세요.").font(.system(size: 10)).foregroundStyle(.secondary)
                Button("인터넷 계정 열기") { openSettings("x-apple.systempreferences:com.apple.preferences.internetaccounts") }
            case .selectionRequired:
                Text("표시할 캘린더를 선택하세요.")
                Button("캘린더 선택") { model.showingSettings = true }
            case .failed:
                Text("캘린더를 불러오지 못했습니다.")
                Button("다시 시도", action: retry)
            default: EmptyView()
            }
        }.font(.system(size: 12)).multilineTextAlignment(.center).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var searchHeader: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("일정 검색", text: $model.searchText).textFieldStyle(.plain).accessibilityLabel("일정 검색")
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("검색 지우기")
                }
            }.padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            Picker("보기", selection: Binding(get: { model.tab }, set: { model.setTab($0) })) {
                ForEach(CalendarTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
        }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
    }
    private var searchPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("시작", selection: $model.searchStart, displayedComponents: .date)
            DatePicker("종료", selection: $model.searchEnd, displayedComponents: .date)
            if model.searchInterval == nil {
                Text("종료일은 시작일 이후여야 합니다.").font(.caption).foregroundStyle(.red)
                Spacer()
            } else {
                Text("\(model.formatted(model.searchStart, "yyyy.MM.dd")) – \(model.formatted(model.searchEnd, "yyyy.MM.dd")) · \(model.searchState == .loaded ? "\(model.searchResults.count)개" : "조회 중")")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                if model.searchState == .loaded {
                    if model.searchResults.isEmpty { emptyMessage("검색 결과 없음") }
                    else {
                        ScrollView {
                            LazyVStack(spacing: 14) {
                                ForEach(model.searchResults) { event in
                                    EventDisplayRow(event: event, time: resultTime(event), highlighted: false,
                                        action: { Task { await model.activate(event, interval: model.searchInterval) } },
                                        reminder: { model.editReminder(event) }, delivery: model.reminders?.snapshot(for: event))
                                }
                            }.padding(.vertical, 5)
                        }
                    }
                } else if model.searchState == .loading { loading }
                else { stateMessage(model.searchState, retry: model.scheduleSearch) }
            }
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }
    private var upcomingPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(model.formatted(model.agendaInterval.start, "M월 d일"))부터 \(model.formatted(model.agendaInterval.end.addingTimeInterval(-1), "M월 d일"))까지")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if model.agendaState == .loaded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.agendaGroups.isEmpty { Text("예정 일정 없음").foregroundStyle(.secondary) }
                        ForEach(model.agendaGroups) { group in
                            Text(model.formatted(group.day, "M월 d일 EEEE")).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                            ForEach(group.events) { event in
                                EventDisplayRow(event: event, time: agendaTime(event, day: group.day), highlighted: false,
                                    action: { Task { await model.activate(event, interval: model.agendaInterval) } },
                                    reminder: { model.editReminder(event) }, delivery: model.reminders?.snapshot(for: event))
                            }
                            Divider()
                        }
                        Button("30일 더 보기") { model.loadMoreAgenda() }.frame(maxWidth: .infinity)
                    }.padding(.vertical, 5)
                }
            } else if model.agendaState == .loading { loading }
            else { stateMessage(model.agendaState, retry: model.refreshAgenda) }
        }.padding(16)
    }
    private var loading: some View { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
    private func emptyMessage(_ message: String) -> some View { Text(message).font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    private func resultTime(_ event: EventOccurrence) -> String {
        model.formatted(event.start, "M/d") + " " + (event.isAllDay ? "종일" : model.formatted(event.start, "HH:mm"))
    }
    private func agendaTime(_ event: EventOccurrence, day: Date) -> String {
        if event.isAllDay { return event.start < day ? "종일 · 진행 중" : "종일" }
        return event.start < day ? "진행 중" : model.formatted(event.start, "HH:mm")
    }
    private var settings: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button { model.showingSettings = false } label: { Label("뒤로", systemImage: "chevron.left") }.buttonStyle(.plain)
                Spacer()
                Text("설정").font(.headline)
            }
            Divider()
            Text("표시할 캘린더").font(.system(size: 12, weight: .semibold))
            if model.access.calendars.isEmpty { accessMessage.frame(height: 150) }
            else {
                Group {
                    VStack(spacing: 12) {
                        ForEach(model.access.calendars) { item in
                            Toggle(isOn: Binding(get: { model.access.selectedCalendarIDs.contains(item.id) }, set: { enabled in
                                Task {
                                    var ids = model.access.selectedCalendarIDs
                                    if enabled { ids.insert(item.id) } else { ids.remove(item.id) }
                                    await model.access.setSelectedCalendarIDs(ids)
                                }
                            })) {
                                HStack(spacing: 8) {
                                    Circle().fill(Color(item.color)).frame(width: 7, height: 7)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).font(.system(size: 12))
                                        Text(item.sourceName).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            if let reminders = model.reminders { ReminderSettingsView(reminders: reminders); Divider() }
            Toggle("로그인 시 실행", isOn: loginToggleBinding).toggleStyle(.switch).font(.system(size: 12))
            if login.state == .requiresApproval {
                Text("시스템 설정에서 로그인 항목을 승인해 주세요.").font(.caption).foregroundStyle(.secondary)
                Button("로그인 항목 설정") { SMAppService.openSystemSettingsLoginItems() }
                Button("등록 취소", action: cancelPendingLoginRegistration)
            }
            if case .failure(let message) = login.state {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("다시 확인") { login.refresh() }
            }
            Spacer(minLength: 0)
            Divider()
            Button("Calendar Bar 종료") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(20)
        }
    }
    private func openSettings(_ url: String) { if let url = URL(string: url) { NSWorkspace.shared.open(url) } }
}
extension Color {
    init(_ color: RGBAColor) { self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha) }
}

@MainActor private struct EventDisplayRow: View {
    let event: EventOccurrence
    let time: String
    let highlighted: Bool
    let action: (() -> Void)?
    let reminder: () -> Void
    let delivery: ReminderDeliverySnapshot?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let action { Button(action: action) { content }.buttonStyle(.plain) }
            else { content }
            Button(action: reminder) {
                Image(systemName: delivery?.scheduled ?? 0 > 0 ? "bell.fill" : delivery?.desiredEnabled == true ? "bell.badge" : "bell")
                    .foregroundStyle(delivery?.scheduled ?? 0 > 0 ? Color.accentColor : .secondary)
            }
                .buttonStyle(.plain).accessibilityLabel("알림 설정: " + event.title + ", " + (delivery?.state.label ?? "알림 꺼짐"))
                .help(delivery.map { "\($0.state.label) · 실제 예약 \($0.scheduled)개 · 보류 \($0.deferred)개" } ?? "알림 꺼짐")
        }.padding(4).background(highlighted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
    private var content: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Color(event.color)).frame(width: 3, height: 29)
            Text(time).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text(event.calendarName).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.contentShape(Rectangle()).frame(maxWidth: .infinity, alignment: .leading)
    }
}
