import AppKit
import CalendarUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: CalendarAppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        coordinator = CalendarAppCoordinator(smoke: arguments.contains("--smoke"))
        if arguments.contains("--show") { coordinator?.show() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        coordinator?.show()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator?.becameActive()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
