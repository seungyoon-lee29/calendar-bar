import AppKit

/// Retain this controller for the app lifetime. Content owns its browsing state;
/// onOpen resets it to today, while onDateChange only updates its notion of today.
@MainActor
public final class MenuBarController: NSObject {
    public let popover: NSPopover
    private let statusItem: NSStatusItem
    private let onOpen: () -> Void
    private let onDateChange: (Date) -> Void
    private var midnightTimer: Timer?
    private var lastDate: DateComponents?
    private var lastTimeZone: TimeZone?
    private var escapeMonitor: Any?

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
        popover.behavior = .transient
        popover.contentViewController = contentViewController
        popover.contentSize = contentSize
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("캘린더 열기")
        }
        let center = NotificationCenter.default
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
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc public func togglePopover() {
        if popover.isShown { close(); return }
        guard let button = statusItem.button else { return }
        refreshDate()
        onOpen()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    public func close() { popover.performClose(nil) }

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
