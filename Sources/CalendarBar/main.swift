import AppKit
import CalendarUI
import MenuBar
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
        QAClickTrace.record(.launch)
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
        QAClickTrace.record(token == nil ? .responseWithoutToken : .responseWithToken)
        Task { @MainActor [weak self] in
            if let token { self?.clicks.receive(token) }
            completionHandler()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        coordinator?.reopen()
        return false
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        QAClickTrace.record(.becameActive)
        coordinator?.becameActive()
    }
}

// Read-only QA diagnostics intentionally bypass AppDelegate, launch settings,
// calendar access, login registration, reminder reconciliation and all mutations.
private func writeReport(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

@MainActor private func runNotificationReport() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let deadline = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        writeReport(["error": "notification_query_timeout"])
        app.terminate(nil)
    }
    Task { @MainActor in
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        // Only known SHA-256 request identifiers are printable. Never inspect
        // notification content, titles, body, userInfo or saved calendar settings.
        func safeID(_ id: String) -> Bool {
            let prefix = "calendarbar.reminder."
            guard id.hasPrefix(prefix) else { return false }
            let suffix = id.dropFirst(prefix.count)
            return suffix.count == 64 && suffix.allSatisfy { "0123456789abcdef".contains($0) }
        }
        let pendingRows: [[String: Any]] = pending.filter { safeID($0.identifier) }.sorted { $0.identifier < $1.identifier }.map { request in
            var row: [String: Any] = ["id": request.identifier]
            if let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() { row["fireDate"] = date.timeIntervalSince1970 }
            return row
        }
        let deliveredRows: [[String: Any]] = delivered.filter { safeID($0.request.identifier) }.sorted { $0.request.identifier < $1.request.identifier }.map {
            ["id": $0.request.identifier, "deliveredAt": $0.date.timeIntervalSince1970]
        }
        deadline.cancel()
        writeReport([
            "authorizationRawValue": settings.authorizationStatus.rawValue,
            "alertRawValue": settings.alertSetting.rawValue,
            "pendingCount": pending.count,
            "deliveredCount": delivered.count,
            "pending": pendingRows,
            "delivered": deliveredRows
        ])
        app.terminate(nil)
    }
    app.run()
}

MainActor.assumeIsolated {
    switch CalendarLaunchOptions.notificationReportMode(arguments: ProcessInfo.processInfo.arguments, bundleID: Bundle.main.bundleIdentifier) {
    case .denied:
        writeReport(["error": "qa_bundle_required"])
    case .readOnly:
        runNotificationReport()
    case .none:
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
