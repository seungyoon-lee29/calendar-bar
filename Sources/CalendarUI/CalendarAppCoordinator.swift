import AppKit
import SwiftUI
import CalendarCore
import CalendarAccess
import CalendarNotifications
import MenuBar

@MainActor public final class CalendarAppCoordinator {
    private let model: CalendarModel
    private let login: LoginItemController
    private let menu: MenuBarController
    private let reminders: ReminderCoordinator
    private var qaWindow: NSWindow?
    private var startup: Task<Void, Never>?
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
    deinit { startup?.cancel() }
    public func show() { menu.show() }
    public func openReminder(token: String) async {
        // Open without resetting the selected date, both warm and cold.
        menu.show(resetToToday: false)
        qaWindow?.makeKeyAndOrderFront(nil)
        await model.routeReminder(token: token)
    }
    public func becameActive() {
        login.refresh(); model.refresh()
        Task { [weak reminders] in await reminders?.refresh() }
    }
}
