import AppKit
import SwiftUI
import CalendarCore
import CalendarAccess
import CalendarNotifications
import MenuBar

@MainActor protocol CalendarPresenting: AnyObject {
    func show(resetToToday: Bool)
    var onUserOpen: (() -> Void)? { get set }
}
extension MenuBarController: CalendarPresenting {}

@MainActor public final class CalendarAppCoordinator {
    private let model: CalendarModel
    private let login: LoginItemController
    private let menu: any CalendarPresenting
    private let reminders: ReminderCoordinator
    private var qaWindow: NSWindow?
    private var startup: Task<Void, Never>?
    private var notificationIntentRevision = 0
    private var resolvingNotification = false
    private var notificationIntentUntil: TimeInterval = 0
    private var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    // Coalesce nearby AppKit reopen callbacks; they do not identify their originating action.
    private static let notificationReopenGrace: TimeInterval = 2
    public init(smoke: Bool = false, qa: Bool = false, qaNotifications: Bool = false, qaWindow: Bool = false, qaSeed: Date? = nil) {
        let access: CalendarAccessController
        let login: LoginItemController
        let reminders: ReminderCoordinator
        if qa || smoke {
            access = CalendarAccessController(backend: QACalendarBackend(now: qaSeed ?? Date()), storage: QASelection(), observeChanges: false)
            let fakeLogin = QALogin()
            login = LoginItemController(backend: fakeLogin, store: fakeLogin)
            let bundle = Bundle.main.bundleIdentifier ?? ""
            // Only a separately identified QA app may touch OS notification state.
            let systemQA = qa && qaNotifications && bundle.hasSuffix(".qa")
            let storage: any ReminderStorage = systemQA
                ? FileReminderStorage(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(bundle + "/qa-reminders.json"))
                : VolatileReminderStorage()
            reminders = ReminderCoordinator(access: access, storage: storage, backend: systemQA ? SystemReminderNotifications() : QANotifications())
        } else {
            access = CalendarAccessController()
            login = LoginItemController()
            reminders = ReminderCoordinator(access: access)
        }
        let model = CalendarModel(access: access, reminders: reminders)
        self.model = model; self.login = login; self.reminders = reminders
        login.initializeForLaunch(automaticallyRegister: !smoke && !qa)
        menu = MenuBarController(
            contentViewController: NSHostingController(rootView: CalendarPopover(model: model, login: login)),
            contentSize: NSSize(width: 340, height: 600),
            onOpen: { model.open(); login.refresh() },
            onDateChange: { [weak reminders] date in
                model.dateChanged(date)
                Task { await reminders?.updateContext(model.calendar.context) }
            }
        )
        menu.onUserOpen = { [weak self] in self?.clearNotificationIntent() }
        if qa && qaWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Calendar Bar · 합성 데이터 QA"
            window.contentViewController = NSHostingController(rootView: CalendarPopover(model: model, login: login))
            window.isReleasedWhenClosed = false
            window.center(); window.makeKeyAndOrderFront(nil)
            self.qaWindow = window
            NSApp.activate(ignoringOtherApps: true)
        }
        startup = Task { [weak reminders] in await reminders?.refresh() }
        model.refresh()
    }
    init(model: CalendarModel, login: LoginItemController, reminders: ReminderCoordinator, menu: any CalendarPresenting, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.model = model; self.login = login; self.reminders = reminders; self.menu = menu
        self.now = now
        menu.onUserOpen = { [weak self] in self?.clearNotificationIntent() }
    }
    deinit { startup?.cancel() }
    public func show() { clearNotificationIntent(); menu.show(resetToToday: true) }
    public func reopen() {
        let notificationIntent = resolvingNotification || now() < notificationIntentUntil
        QAClickTrace.record(notificationIntent ? .reopenNotification : .reopenOrdinary)
        menu.show(resetToToday: !notificationIntent)
    }
    private func clearNotificationIntent() {
        notificationIntentRevision += 1
        resolvingNotification = false
        notificationIntentUntil = 0
    }
    public func openReminder(token: String) async {
        QAClickTrace.record(.routeBegin)
        notificationIntentRevision += 1
        let revision = notificationIntentRevision
        resolvingNotification = true
        notificationIntentUntil = now() + Self.notificationReopenGrace
        defer {
            if revision == notificationIntentRevision {
                resolvingNotification = false
                notificationIntentUntil = now() + Self.notificationReopenGrace
            }
        }
        // Open without resetting the selected date, both warm and cold.
        menu.show(resetToToday: false)
        qaWindow?.makeKeyAndOrderFront(nil)
        await model.routeReminder(token: token)
        QAClickTrace.record(model.highlightedEventID != nil ? .routeHighlighted : model.navigationMessage != nil ? .routeMessage : .routeNoDestination)
    }
    public func becameActive() {
        login.refresh(); model.refresh()
        Task { [weak reminders] in await reminders?.refresh() }
    }
}
