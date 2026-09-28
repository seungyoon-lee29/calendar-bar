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

    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator?.becameActive()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
