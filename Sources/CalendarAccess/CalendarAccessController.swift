import Foundation
import AppKit
import Observation
import EventKit
import CalendarCore

public struct CalendarDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let sourceName: String
    public let color: RGBAColor
    public init(id: String, name: String, sourceName: String, color: RGBAColor) {
        self.id = id; self.name = name; self.sourceName = sourceName; self.color = color
    }
}
public enum CalendarPermission: Equatable, Sendable { case unknown, authorized, denied, restricted }
public enum CalendarViewState: Equatable, Sendable {
    case connectionRequired, noCalendars, selectionRequired, loading, loaded, failed
}
public protocol CalendarBackend: Sendable {
    func permission() async -> CalendarPermission
    func requestAccess() async throws
    func calendars() async throws -> [CalendarDescriptor]
    func events(interval: DateInterval, calendarIDs: Set<String>) async throws -> [EventOccurrence]
}
@MainActor public protocol CalendarSelectionStorage {
    func load() -> Set<String>
    func save(_ ids: Set<String>)
}
@MainActor public final class UserDefaultsCalendarSelection: CalendarSelectionStorage {
    private let defaults: UserDefaults
    private let key = "selectedCalendarIDs"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
    public func save(_ ids: Set<String>) { defaults.set(ids.sorted(), forKey: key) }
}

@Observable @MainActor public final class CalendarAccessController {
    public private(set) var permission: CalendarPermission = .unknown
    public private(set) var state: CalendarViewState = .connectionRequired
    public private(set) var calendars: [CalendarDescriptor] = []
    public private(set) var events: [EventOccurrence] = []
    public private(set) var selectedCalendarIDs: Set<String>
    public var effectiveSelectedCalendarIDs: Set<String> { selectedCalendarIDs.intersection(calendars.map(\.id)) }
    public var errorMessage: String? { state == .failed ? "캘린더를 불러오지 못했습니다. 다시 시도해 주세요." : nil }
    @ObservationIgnored private let backend: any CalendarBackend
    @ObservationIgnored private let storage: any CalendarSelectionStorage
    @ObservationIgnored private var interval: DateInterval?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var requestInFlight = false
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init(backend: any CalendarBackend = EventKitBackend(), storage: (any CalendarSelectionStorage)? = nil, observeChanges: Bool = true) {
        self.backend = backend
        let storage = storage ?? UserDefaultsCalendarSelection()
        self.storage = storage
        selectedCalendarIDs = storage.load()
        if observeChanges {
            observe(.default, name: .EKEventStoreChanged)
            observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification)
        }
    }
    deinit { for (center, token) in observers { center.removeObserver(token) } }
    private func observe(_ center: NotificationCenter, name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let interval = self.interval else { return }
                await self.refresh(interval: interval)
            }
        }
        observers.append((center, token))
    }
    public func setSelectedCalendarIDs(_ ids: Set<String>) async {
        selectedCalendarIDs = ids
        storage.save(ids)
        if let interval { await refresh(interval: interval) }
    }
    /// Invoke only in response to the user's connect action.
    public func requestAccess() async {
        guard !requestInFlight else { return }
        requestInFlight = true
        defer { requestInFlight = false }
        do { try await backend.requestAccess() }
        catch {
            // Refresh still verifies the actual OS permission after a request error.
            await refreshAfterAccess()
            return
        }
        // Use the current interval/selection; either can change while TCC is open.
        await refreshAfterAccess()
    }
    private func refreshAfterAccess() async {
        if let interval { await refresh(interval: interval); return }
        generation += 1
        let revision = generation
        let currentPermission = await backend.permission()
        guard revision == generation else { return }
        permission = currentPermission
        clearForPermission()
    }
    public func refresh(interval: DateInterval) async {
        self.interval = interval
        generation += 1
        let revision = generation
        events = []
        state = .loading
        let permission = await backend.permission()
        guard revision == generation else { return }
        self.permission = permission
        guard permission == .authorized else { clearForPermission(); return }
        do {
            let available = try await backend.calendars()
            guard revision == generation else { return }
            let ids = selectedCalendarIDs.intersection(available.map(\.id))
            let loaded: [EventOccurrence]
            if !available.isEmpty && !ids.isEmpty {
                loaded = try await backend.events(interval: interval, calendarIDs: ids)
            } else { loaded = [] }
            let currentPermission = await backend.permission()
            guard revision == generation else { return }
            self.permission = currentPermission
            guard currentPermission == .authorized else { clearForPermission(); return }
            calendars = available
            events = loaded.filter { ids.contains($0.calendarID) && Self.overlaps($0, interval) }
            state = available.isEmpty ? .noCalendars : ids.isEmpty ? .selectionRequired : .loaded
        } catch {
            let currentPermission = await backend.permission()
            guard revision == generation else { return }
            self.permission = currentPermission
            guard currentPermission == .authorized else { clearForPermission(); return }
            events = []
            state = .failed
        }
    }
    private func clearForPermission() {
        calendars = []; events = []
        state = permission == .authorized ? .selectionRequired : .connectionRequired
    }
    static func overlaps(_ event: EventOccurrence, _ interval: DateInterval) -> Bool {
        guard interval.duration > 0 else { return false }
        if event.start == event.end { return event.start >= interval.start && event.start < interval.end }
        return event.end > event.start && event.start < interval.end && event.end > interval.start
    }
}
