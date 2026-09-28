import AppKit

/// Retain this controller for the app lifetime. Content owns its browsing state;
/// onOpen resets it to today, while onDateChange only updates its notion of today.
@MainActor
public final class MenuBarController: NSObject, NSPopoverDelegate {
    public let popover: NSPopover
    public var onUserOpen: (() -> Void)?
    private let presentation = PopoverPresentation()
    private let statusItem: NSStatusItem
    private let onOpen: () -> Void
    private let onDateChange: (Date) -> Void
    private var midnightTimer: Timer?
    private var lastDate: DateComponents?
    private var lastTimeZone: TimeZone?
    private var escapeMonitor: Any?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    public init(
        contentViewController: NSViewController,
        contentSize: NSSize = NSSize(width: 340, height: 440),
        onOpen: @escaping () -> Void = {},
        onDateChange: @escaping (Date) -> Void = { _ in }
    ) {
        self.onOpen = onOpen
        self.onDateChange = onDateChange
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        super.init()
        statusItem.autosaveName = "CalendarBar.date"
        statusItem.isVisible = true
        popover.delegate = self
        popover.behavior = .transient
        popover.contentViewController = contentViewController
        popover.contentSize = contentSize
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("캘린더 열기")
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(applicationDeactivated), name: NSApplication.didResignActiveNotification, object: NSApp)
        for name in [NSNotification.Name.NSCalendarDayChanged,
                     NSNotification.Name.NSSystemTimeZoneDidChange,
                     NSNotification.Name.NSSystemClockDidChange] {
            center.addObserver(self, selector: #selector(clockChanged), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(clockChanged), name: NSWorkspace.didWakeNotification, object: nil
        )
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, event.keyCode == 53 else { return event }
            self.close()
            return nil
        }
        refreshDate()
    }

    deinit {
        midnightTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    nonisolated static func hasVisibleAnchor(_ buttonFrame: NSRect, on screenFrame: NSRect?) -> Bool {
        guard let screenFrame, !buttonFrame.isEmpty else { return false }
        return screenFrame.intersects(buttonFrame)
    }

    @objc public func togglePopover() {
        if popover.isShown { close(); return }
        onUserOpen?()
        show(resetToToday: true)
    }

    /// Notification navigation has already selected its destination.
    public func show(resetToToday: Bool = true) {
        presentation.request(activate: { NSApp.activate(ignoringOtherApps: true) }) { [weak self] in
            self?.attemptPresentation(resetToToday: resetToToday) ?? true
        }
    }

    private func attemptPresentation(resetToToday: Bool) -> Bool {
        if popover.isShown { return true }
        guard NSApp.isActive else { return false }
        statusItem.isVisible = true
        guard let button = statusItem.button, let window = button.window, window.isVisible,
              !button.isHiddenOrHasHiddenAncestor else { return false }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        // A detached status item can have a visible window at (0, -22) with no screen.
        // Present only below the real menu bar icon, never from that placeholder.
        guard Self.hasVisibleAnchor(buttonFrame, on: window.screen?.frame) else { return false }
        refreshDate()
        if resetToToday { onOpen() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        return popover.isShown
    }

    public func close() { presentation.cancel(); popover.performClose(nil) }

    public func popoverDidShow(_ notification: Notification) {
        removeClickMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            // Let the status button's action toggle the popover itself.
            if event.window !== self.popover.contentViewController?.view.window,
               event.window !== self.statusItem.button?.window {
                self.close()
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.close()
        }
    }

    public func popoverWillClose(_ notification: Notification) { removeClickMonitors() }

    private func removeClickMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }

    @objc private func applicationDeactivated(_ notification: Notification) {
        close()
    }

    public func setContentSize(_ size: NSSize) { popover.contentSize = size }

    @objc private func clockChanged(_ notification: Notification) { refreshDate() }

    private func refreshDate() {
        let now = Date()
        let zone = TimeZone.current
        let components = StatusDate.calendar(zone).dateComponents([.era, .year, .month, .day], from: now)
        if components != lastDate || zone != lastTimeZone {
            lastDate = components
            lastTimeZone = zone
            statusItem.button?.image = Self.calendarImage(day: StatusDate.day(at: now, timeZone: zone))
            statusItem.button?.toolTip = "캘린더 열기 · 오늘 \(components.month!)/\(components.day!)"
            onDateChange(now)
        }
        midnightTimer?.invalidate()
        let timer = Timer(fire: StatusDate.nextMidnight(after: now, timeZone: zone), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDate() }
        }
        midnightTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func calendarImage(day: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 17, height: 16), xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.2
            outline.stroke()
            let top = NSBezierPath()
            top.move(to: NSPoint(x: 2, y: 13.5)); top.line(to: NSPoint(x: 18, y: 13.5))
            for x in [6.0, 14.0] {
                top.move(to: NSPoint(x: x, y: 16)); top.line(to: NSPoint(x: x, y: 19))
            }
            top.lineWidth = 1.2
            top.stroke()
            let text = "\(day)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.black]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: 1.5), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "오늘 \(day)일"
        return image
    }
}
