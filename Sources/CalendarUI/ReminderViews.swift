import SwiftUI
import AppKit
import CalendarCore
import CalendarNotifications

extension ReminderDeliveryState {
    var label: String {
        switch self {
        case .updating: return "예약 확인 중"
        case .scheduled: return "예약됨"
        case .partial: return "일부 예약 · 나머지 확인 필요"
        case .permissionRequired: return "알림 또는 캘린더 권한 필요"
        case .failed: return "예약 실패 · 다시 시도해 주세요"
        case .needsConfirmation: return "일정 변경 확인 필요"
        case .noFuture: return "예약된 미래 알림 없음"
        }
    }
}
@MainActor struct ReminderStatusView: View {
    let snapshot: ReminderDeliverySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.desiredEnabled ? "알림 사용 설정" : "알림 꺼짐").font(.caption)
            Text(snapshot.state.label).font(.caption).foregroundStyle(.secondary)
            Text("실제 예약 \(snapshot.scheduled)개 · 보류 \(snapshot.deferred)개").font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}
@MainActor struct ReminderEditorView: View {
    @Bindable var model: CalendarModel
    let reminders: ReminderCoordinator
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button("닫기") { model.cancelReminder() }
                    Spacer()
                    Text("일정 알림").font(.headline)
                }
                if let event = model.selectedReminderEvent, let draft = model.reminderDraft, model.canDisplayReminder {
                    Text(event.title).font(.headline)
                    Text(model.formatted(event.start, event.isAllDay ? "M월 d일 · 종일" : "M월 d일 HH:mm")).font(.caption).foregroundStyle(.secondary)
                    ReminderStatusView(snapshot: reminders.snapshot(for: event))
                    Divider()
                    if event.isRecurring {
                        Picker("적용 범위", selection: Binding(get: { model.reminderDraft?.scope ?? .thisOccurrence }, set: { model.reminderDraft?.scope = $0 })) {
                            Text("이번 일정만").tag(ReminderScope.thisOccurrence)
                            Text("이 일정부터 앞으로").tag(ReminderScope.thisAndFuture).disabled(!draft.canUseFuture)
                        }
                        if !draft.canUseFuture { Text("반복 일정의 연결을 확인하지 못해 앞으로 적용할 수 없습니다.").font(.caption).foregroundStyle(.secondary) }
                        if draft.occurrenceAnchor == nil { Text("원래 발생 시점을 확인할 수 없습니다. 캘린더를 새로고침한 뒤 다시 시도해 주세요.").font(.caption).foregroundStyle(.red) }
                    }
                    if draft.requiresFormatConfirmation {
                        Text("일정이 시간 일정 또는 종일 일정으로 변경되었습니다. 새 형식의 시간을 확인해 주세요.").font(.caption)
                        Toggle("변경된 일정 형식 확인", isOn: Binding(get: { model.reminderDraft?.formatConfirmed ?? false }, set: { model.reminderDraft?.formatConfirmed = $0 }))
                    }
                    TriggerFields(rows: Binding(get: { model.reminderDraft?.rows ?? [] }, set: { model.reminderDraft?.rows = $0 }), format: draft.format)
                    Button("기본 시간 적용") { model.reminderDraft?.apply(reminders.settings.defaults) }
                    Text("기본 시간을 복사합니다. 이후 기본값을 바꿔도 이 일정에는 소급 적용되지 않습니다.").font(.caption).foregroundStyle(.secondary)
                    if let error = model.reminderError { Text(error).font(.caption).foregroundStyle(.red) }
                    HStack {
                        Button("알림 끄기") { Task { await model.saveReminder(enabled: false) } }
                        Spacer()
                        Button("저장") { Task { await model.saveReminder(enabled: true) } }.buttonStyle(.borderedProminent)
                    }.disabled(model.reminderBusy || draft.occurrenceAnchor == nil)
                    if event.isRecurring, let existing = draft.existing, existing.scope == .thisOccurrence {
                        Button("개별 설정 해제 · 반복 설정 따르기") { Task { await model.resumeInheritedReminder() } }.disabled(model.reminderBusy)
                    }
                    ReminderPermissionView(reminders: reminders)
                    Button("예약 다시 확인") { Task { await reminders.retry() } }
                    Text("일정 자체는 변경하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
    }
}
@MainActor struct TriggerFields: View {
    @Binding var rows: [ReminderTriggerDraft]
    let format: ReminderFormat
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($rows) { $row in
                HStack(spacing: 5) {
                    if format == .timed {
                        TextField("0", text: $row.hours).accessibilityLabel("알림 몇 시간 전").frame(width: 48)
                        Text("시간")
                        TextField("10", text: $row.minute).accessibilityLabel("알림 몇 분 전").frame(width: 42)
                        Text("분 전")
                    } else {
                        TextField("1", text: $row.days).accessibilityLabel("알림 며칠 전").frame(width: 38)
                        Text("일 전")
                        TextField("21", text: $row.wallHour).accessibilityLabel("알림 시 0에서 23").frame(width: 32)
                        Text(":")
                        TextField("00", text: $row.minute).accessibilityLabel("알림 분 0에서 59").frame(width: 32)
                    }
                    Spacer(minLength: 0)
                    Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).accessibilityLabel("이 알림 시간 삭제")
                }.textFieldStyle(.roundedBorder).font(.system(size: 12))
            }
            Button("알림 시간 추가") { rows.append(ReminderTriggerDraft(format == .timed ? try! .timed(hours: 0, minutes: 10) : try! .allDay(daysBefore: 1, hour: 21, minute: 0))) }
            Text(format == .timed ? "최소 1분 전 · 분은 0–59" : "0일 전은 당일 · 시 0–23, 분 0–59 · 현재 시간대 기준").font(.caption).foregroundStyle(.secondary)
        }
    }
}
@MainActor struct ReminderPermissionView: View {
    let reminders: ReminderCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !reminders.permission.canSchedule {
                Text("알림이 허용되어야 실제로 예약할 수 있습니다.").font(.caption)
                Button("알림 권한 요청") { Task { await reminders.requestPermission() } }
                Button("알림 시스템 설정") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                }
            }
            if let error = reminders.permissionRequestError { Text(error).font(.caption).foregroundStyle(.red) }
            if let error = reminders.storageError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
@MainActor struct ReminderSettingsView: View {
    let reminders: ReminderCoordinator
    @State private var timed: [ReminderTriggerDraft] = []
    @State private var allDay: [ReminderTriggerDraft] = []
    @State private var error: String?
    @State private var saved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("알림").font(.headline)
            Text("실제 예약 \(reminders.scheduled)개 · 보류 \(reminders.deferred)개 · 확인 필요 \(reminders.needsConfirmation)개").font(.caption)
            if let date = reminders.lastScheduled { Text("최근 예약 확인: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            else { Text("아직 예약된 알림이 없습니다.").font(.caption).foregroundStyle(.secondary) }
            Button("예약 다시 확인") { Task { await reminders.retry() } }
            ReminderPermissionView(reminders: reminders)
            Toggle("알림 제목과 시간 숨기기", isOn: Binding(get: { reminders.settings.hideContent }, set: { value in
                Task { do { try await reminders.setHideContent(value); error = nil } catch { self.error = "알림 내용 설정을 저장하지 못했습니다." } }
            })).toggleStyle(.checkbox)
            Text("시간 일정 기본값").font(.subheadline)
            TriggerFields(rows: $timed, format: .timed)
            Text("종일 일정 기본값").font(.subheadline)
            TriggerFields(rows: $allDay, format: .allDay)
            Button("기본 시간 저장") {
                Task {
                    do {
                        try await reminders.updateDefaults(ReminderDefaults(timed: timed.map { try $0.trigger(format: .timed) }, allDay: allDay.map { try $0.trigger(format: .allDay) }))
                        error = nil; saved = true
                    } catch { self.error = "기본 시간을 저장하지 못했습니다. 각 형식에 유효한 시간을 하나 이상 입력해 주세요."; saved = false }
                }
            }
            if saved { Text("기본 시간 저장됨 · 기존 일정은 그대로 유지됩니다.").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("일정마다 알림을 직접 켜야 합니다. 앞으로 1년 범위에서 가까운 알림 최대 48개를 예약하며 나머지는 앱 실행 중 보충합니다. 오래 닫아 두었다면 앱을 다시 열어 주세요. 앱 종료 중 변경·삭제·권한 회수는 반영되지 않아 이전 제목의 알림이 남을 수 있습니다.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            timed = reminders.settings.defaults.timed.map(ReminderTriggerDraft.init)
            allDay = reminders.settings.defaults.allDay.map(ReminderTriggerDraft.init)
        }
    }
}
