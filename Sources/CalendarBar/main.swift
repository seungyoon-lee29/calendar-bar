import AppKit
import CalendarUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var coordinator: CalendarAppCoordinator?
    private let clicks = ReminderClickRouter()
    private let options = CalendarLaunchOptions(arguments: ProcessInfo.processInfo.arguments, bundleID: Bundle.main.bundleIdentifier)

    override init() {
        super.init()
        if !options.qa && !options.smoke || options.qaNotifications {
            UNUserNotificationCenter.current().delegate = self
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = CalendarAppCoordinator(smoke: options.smoke, qa: options.qa, qaNotifications: options.qaNotifications, qaWindow: options.qaWindow, qaSeed: options.qaSeed)
        self.coordinator = coordinator
        clicks.install { [weak coordinator] token in await coordinator?.openReminder(token: token) }
        if options.show { coordinator.show() }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let token = response.notification.request.content.userInfo["token"] as? String
        Task { @MainActor [weak self] in
            if let token { self?.clicks.receive(token) }
            completionHandler()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        coordinator?.show()
        return false
    }
    func applicationDidBecomeActive(_ notification: Notification) { coordinator?.becameActive() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
