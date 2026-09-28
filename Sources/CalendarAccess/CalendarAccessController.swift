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
    func resolve(identity: ReminderIdentity, anchor: OccurrenceAnchor?, isRecurring: Bool, searchInterval: DateInterval?, calendarIDs: Set<String>) async throws -> CalendarEventResolution
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
    public private(set) var calendars: [CalendarDescriptor] = []
    public private(set) var selectedCalendarIDs: Set<String>
    private var snapshots: [CalendarQueryChannel: CalendarQuerySnapshot] = [:]
    public var state: CalendarViewState { snapshot(for: .month).state }
    public var events: [EventOccurrence] { snapshot(for: .month).events }
    public var effectiveSelectedCalendarIDs: Set<String> { selectedCalendarIDs.intersection(calendars.map(\.id)) }
    public var errorMessage: String? { state == .failed ? "캘린더를 불러오지 못했습니다. 다시 시도해 주세요." : nil }
    @ObservationIgnored private let backend: any CalendarBackend
    @ObservationIgnored private let storage: any CalendarSelectionStorage
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var requestInFlight = false
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var streams: [UUID: AsyncStream<CalendarAccessChange>.Continuation] = [:]

    public init(backend: any CalendarBackend = EventKitBackend(), storage: (any CalendarSelectionStorage)? = nil, observeChanges: Bool = true) {
        self.backend = backend
        let storage = storage ?? UserDefaultsCalendarSelection()
        self.storage = storage
        selectedCalendarIDs = storage.load()
        if observeChanges {
            observe(.default, name: .EKEventStoreChanged, reason: .eventStore)
            observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification, reason: .wake)
            observe(.default, name: NSApplication.didBecomeActiveNotification, reason: .permission)
        }
    }
    deinit {
        for (center, token) in observers { center.removeObserver(token) }
        for continuation in streams.values { continuation.finish() }
    }
    public func snapshot(for channel: CalendarQueryChannel) -> CalendarQuerySnapshot {
        snapshots[channel] ?? CalendarQuerySnapshot(interval: nil, generation: 0, state: .connectionRequired, events: [])
    }
    public func changes() -> AsyncStream<CalendarAccessChange> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            streams[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.streams.removeValue(forKey: id) } }
        }
    }
    private func emit(_ reason: CalendarAccessChange) { for continuation in streams.values { continuation.yield(reason) } }
    private func observe(_ center: NotificationCenter, name: Notification.Name, reason: CalendarAccessChange) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.invalidate(reason: reason) }
        }
        observers.append((center, token))
    }
    private func clearAll(state: CalendarViewState, except preserved: CalendarQueryChannel? = nil) {
        epoch += 1
        for channel in CalendarQueryChannel.allCases where channel != preserved {
            let old = snapshot(for: channel)
            snapshots[channel] = CalendarQuerySnapshot(interval: old.interval, generation: old.generation + 1, state: state, events: [])
        }
    }
    public func invalidate(reason: CalendarAccessChange) async {
        clearAll(state: .loading)
        emit(reason)
        let ranges = snapshots.compactMap { channel, snapshot in snapshot.interval.map { (channel, $0) } }
        if ranges.isEmpty {
            permission = await backend.permission()
            if permission != .authorized { calendars = []; clearAll(state: .connectionRequired) }
        }
        for (channel, interval) in ranges { await refresh(channel: channel, interval: interval) }
    }
    public func setSelectedCalendarIDs(_ ids: Set<String>) async {
        selectedCalendarIDs = ids
        storage.save(ids)
        await invalidate(reason: .selection)
    }
    /// Invoke only in response to the user's connect action.
    public func requestAccess() async {
        guard !requestInFlight else { return }
        requestInFlight = true
        defer { requestInFlight = false }
        do { try await backend.requestAccess() } catch { /* Verify actual permission even after request failure. */ }
        await invalidate(reason: .permission)
    }
    private func acceptPermission(_ value: CalendarPermission) -> Bool {
        let changed = permission != value
        permission = value
        if value != .authorized {
            calendars = []; clearAll(state: .connectionRequired)
            if changed { emit(.permission) }
            return false
        }
        if changed { emit(.permission) }
        return true
    }
    public func refresh(interval: DateInterval) async { await refresh(channel: .month, interval: interval) }
    public func refresh(channel: CalendarQueryChannel, interval: DateInterval) async {
        let revision = snapshot(for: channel).generation + 1
        let global = epoch
        snapshots[channel] = CalendarQuerySnapshot(interval: interval, generation: revision, state: .loading, events: [])
        func current() -> Bool { epoch == global && snapshot(for: channel).generation == revision }
        func publish(_ state: CalendarViewState, _ events: [EventOccurrence] = []) {
            snapshots[channel] = CalendarQuerySnapshot(interval: interval, generation: revision, state: state, events: events)
        }
        let access = await backend.permission()
        guard current(), acceptPermission(access) else { return }
        guard CalendarRangeQuery.isValid(interval) else { publish(.failed); return }
        do {
            let available = try await backend.calendars()
            guard current() else { return }
            let ids = selectedCalendarIDs.intersection(available.map(\.id))
            let loaded = ids.isEmpty ? [] : try await CalendarRangeQuery.fetch(backend: backend, interval: interval, calendarIDs: ids)
            let access = await backend.permission()
            guard current(), acceptPermission(access) else { return }
            if !calendars.isEmpty && calendars != available {
                clearAll(state: .loading, except: channel)
                emit(.eventStore)
            }
            calendars = available
            publish(available.isEmpty ? .noCalendars : ids.isEmpty ? .selectionRequired : .loaded, loaded)
        } catch {
            let access = await backend.permission()
            guard current(), acceptPermission(access) else { return }
            publish(.failed)
        }
    }
    public func resolve(identity: ReminderIdentity, anchor: OccurrenceAnchor?, isRecurring: Bool, searchInterval: DateInterval? = nil) async -> CalendarEventResolution {
        let global = epoch
        let access = await backend.permission()
        guard global == epoch else { return .outsideQuery }
        guard acceptPermission(access) else { return .connectionRequired }
        guard selectedCalendarIDs.contains(identity.calendarID) else { return .outsideSelectedScope }
        do {
            let available = try await backend.calendars()
            guard global == epoch else { return .outsideQuery }
            let ids = selectedCalendarIDs.intersection(available.map(\.id))
            guard ids.contains(identity.calendarID) else { return .outsideSelectedScope }
            let result = try await backend.resolve(identity: identity, anchor: anchor, isRecurring: isRecurring, searchInterval: searchInterval, calendarIDs: ids)
            let access = await backend.permission()
            guard global == epoch else { return .outsideQuery }
            guard acceptPermission(access) else { return .connectionRequired }
            return result
        } catch {
            let access = await backend.permission()
            guard global == epoch else { return .outsideQuery }
            guard acceptPermission(access) else { return .connectionRequired }
            return .failed
        }
    }
    static func overlaps(_ event: EventOccurrence, _ interval: DateInterval) -> Bool {
        guard interval.duration > 0 else { return false }
        if event.start == event.end { return event.start >= interval.start && event.start < interval.end }
        return event.end > event.start && event.start < interval.end && event.end > interval.start
    }
}
