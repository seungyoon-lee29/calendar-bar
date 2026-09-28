import Foundation
import CryptoKit
import UserNotifications
import Observation
import CalendarCore
import CalendarAccess

public struct ReminderLink: Codable, Equatable, Sendable {
    public let identity: ReminderIdentity
    public let anchor: OccurrenceAnchor
    public let isRecurring: Bool
    public let ruleID: UUID
}
public struct ReminderSettings: Codable, Equatable, Sendable {
    public var version = 1
    public var rules = ReminderRules()
    public var defaults = ReminderDefaults()
    public var hideContent = false
    public var links: [String: ReminderLink] = [:]
    public var recurringRules: [UUID: Bool] = [:]
    public init() {}
    func validated() throws -> Self {
        guard version == 1 else { throw ReminderStorageError.unsupportedVersion }
        guard Set(rules.rules.map(\.id)).count == rules.rules.count,
              !defaults.timed.isEmpty, !defaults.allDay.isEmpty,
              defaults.timed.allSatisfy({ $0.format == .timed }),
              defaults.allDay.allSatisfy({ $0.format == .allDay }) else { throw ReminderStorageError.corrupt }
        return self
    }
}
public enum ReminderStorageError: Error { case unsupportedVersion, corrupt, unavailable, missingRecurrenceEvidence }
public protocol ReminderStorage: Sendable {
    func load() throws -> ReminderSettings
    func save(_ settings: ReminderSettings) throws
}
public struct FileReminderStorage: ReminderStorage {
    public let url: URL
    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CalendarBar/reminders.json")) { self.url = url }
    public func load() throws -> ReminderSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReminderSettings() }
        let data = try Data(contentsOf: url)
        struct Version: Decodable { let version: Int }
        guard let header = try? JSONDecoder().decode(Version.self, from: data) else { throw ReminderStorageError.corrupt }
        guard header.version == 1 else { throw ReminderStorageError.unsupportedVersion }
        guard let settings = try? JSONDecoder().decode(ReminderSettings.self, from: data) else { throw ReminderStorageError.corrupt }
        return try settings.validated()
    }
    public func save(_ settings: ReminderSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: url, options: .atomic)
    }
}
public struct ReminderPermission: Equatable, Sendable {
    public let authorizationRawValue: Int
    public let alertRawValue: Int
    public var canSchedule: Bool { [2, 3, 4].contains(authorizationRawValue) && alertRawValue == 2 }
    public init(authorizationRawValue: Int, alertRawValue: Int) { self.authorizationRawValue = authorizationRawValue; self.alertRawValue = alertRawValue }
}
public struct ReminderRequest: Equatable, Sendable {
    public static let prefix = "calendarbar.reminder."
    public let id: String
    public let fireDate: Date
    public let title: String
    public let body: String
    public let token: String
    func matches(_ other: Self) -> Bool { id == other.id && token == other.token && title == other.title && body == other.body && abs(fireDate.timeIntervalSince(other.fireDate)) < 1 }
    public static func identifier(identity: ReminderIdentity, anchor: OccurrenceAnchor, trigger: ReminderTrigger) -> String {
        struct Key: Encodable { let calendar: String; let item: String; let anchor: OccurrenceAnchor; let trigger: ReminderTrigger }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try! encoder.encode(Key(calendar: identity.calendarID, item: identity.confirmedSeriesKey ?? identity.localItemID, anchor: anchor, trigger: trigger))
        return prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
public protocol ReminderNotificationBackend: Sendable {
    func permission() async -> ReminderPermission
    func requestPermission() async throws
    func pending() async -> [ReminderRequest]
    func add(_ request: ReminderRequest) async throws
    func remove(_ identifiers: [String]) async
    func deliveredIdentifiers() async -> [String]
}
public struct SystemReminderNotifications: ReminderNotificationBackend {
    public init() {}
    public func permission() async -> ReminderPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return ReminderPermission(authorizationRawValue: settings.authorizationStatus.rawValue, alertRawValue: settings.alertSetting.rawValue)
    }
    public func requestPermission() async throws { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    public func pending() async -> [ReminderRequest] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().compactMap { request in
            guard request.identifier.hasPrefix(ReminderRequest.prefix), let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(), let token = request.content.userInfo["token"] as? String else { return nil }
            return ReminderRequest(id: request.identifier, fireDate: date, title: request.content.title, body: request.content.body, token: token)
        }
    }
    public func add(_ request: ReminderRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title; content.body = request.body; content.sound = .default; content.userInfo = ["token": request.token]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: request.fireDate)
        components.timeZone = calendar.timeZone
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
    }
    public func remove(_ identifiers: [String]) async {
        let own = identifiers.filter { $0.hasPrefix(ReminderRequest.prefix) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: own)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: own)
    }
    public func deliveredIdentifiers() async -> [String] { await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(ReminderRequest.prefix) } }
}
public enum ReminderDeliveryState: String, Sendable { case updating, scheduled, partial, permissionRequired, failed, needsConfirmation, noFuture }
public struct ReminderDeliverySnapshot: Equatable, Sendable {
    public var desiredEnabled: Bool
    public var state: ReminderDeliveryState
    public var scheduled: Int = 0
    public var deferred: Int = 0
}

@Observable @MainActor public final class ReminderCoordinator {
    public private(set) var settings = ReminderSettings()
    public private(set) var permission = ReminderPermission(authorizationRawValue: 0, alertRawValue: 0)
    public private(set) var snapshots: [UUID: ReminderDeliverySnapshot] = [:]
    public private(set) var eventSnapshots: [EventOccurrence.ID: ReminderDeliverySnapshot] = [:]
    public private(set) var storageError: String?
    public private(set) var permissionRequestError: String?
    public private(set) var lastScheduled: Date?
    public var scheduled: Int { snapshots.values.reduce(0) { $0 + $1.scheduled } }
    public var deferred: Int { snapshots.values.reduce(0) { $0 + $1.deferred } }
    public var needsConfirmation: Int { snapshots.values.filter { $0.state == .needsConfirmation }.count }
    @ObservationIgnored private let access: CalendarAccessController
    @ObservationIgnored private let storage: any ReminderStorage
    @ObservationIgnored private let backend: any ReminderNotificationBackend
    @ObservationIgnored private var context: CalendarContext
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let budget: Int
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var purgeDelivered = false
    @ObservationIgnored private let observesChanges: Bool
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    public init(access: CalendarAccessController, storage: (any ReminderStorage)? = nil, backend: any ReminderNotificationBackend = SystemReminderNotifications(), context: CalendarContext = CalendarContext(timeZone: .current), now: @escaping @Sendable () -> Date = { Date() }, budget: Int = 48, observeChanges: Bool = true, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.access = access; self.storage = storage ?? FileReminderStorage(); self.backend = backend; self.context = context; self.now = now; self.budget = max(0, budget); self.observesChanges = observeChanges; self.sleep = sleep
        do { settings = try self.storage.load().validated() } catch { storageError = "알림 설정을 읽지 못했습니다. 기존 파일을 보존했습니다." }
        purgeDelivered = settings.hideContent
        if observeChanges {
            let stream = access.changes()
            changesTask = Task { [weak self] in
                for await _ in stream { guard !Task.isCancelled else { break }; _ = self?.enqueueRefresh() }
            }
            armTimer()
        }
    }
    deinit { changesTask?.cancel(); timer?.cancel(); worker?.cancel() }
    private func armTimer(delay: TimeInterval = 300) {
        guard observesChanges else { return }
        timer?.cancel()
        let sleep = self.sleep
        timer = Task { [weak self] in
            do { try await sleep(max(1, min(300, delay))) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }
    private func persist(_ value: ReminderSettings) throws {
        guard storageError == nil else { throw ReminderStorageError.unavailable }
        do { try storage.save(value); settings = value } catch { throw error }
    }
    public func save(rule: ReminderRule, event: EventOccurrence? = nil) async throws {
        var value = settings
        guard event != nil || value.recurringRules[rule.id] != nil || rule.identity.confirmedSeriesKey != nil else { throw ReminderStorageError.missingRecurrenceEvidence }
        if let event {
            guard rule.identity.matchesOccurrenceItem(event.reminderIdentity) else { throw ReminderStorageError.missingRecurrenceEvidence }
        }
        // Retain the original nonrecurring target anchor when editing by rule ID.
        let old = value.rules.rules.last { $0.id == rule.id || event?.isRecurring == false && $0.scope == .thisOccurrence && $0.identity.matchesItem(rule.identity) }
        let saved: ReminderRule
        if let old, old.scope == .thisOccurrence, value.recurringRules[old.id] != true, old.identity.confirmedSeriesKey == nil, old.identity.matchesItem(rule.identity) {
            saved = try ReminderRule(id: rule.id, identity: rule.identity, anchor: old.anchor, scope: rule.scope, format: rule.format, enabled: rule.enabled, triggers: rule.triggers)
        } else { saved = rule }
        try value.rules.replace(with: saved); value.recurringRules[saved.id] = event?.isRecurring ?? value.recurringRules[saved.id] ?? (saved.identity.confirmedSeriesKey != nil); try persist(value); await refresh()
    }
    public func updateDefaults(_ defaults: ReminderDefaults) async throws {
        guard !defaults.timed.isEmpty, !defaults.allDay.isEmpty, defaults.timed.allSatisfy({ $0.format == .timed }), defaults.allDay.allSatisfy({ $0.format == .allDay }) else { throw CalendarValueError.invalidTrigger }
        var value = settings; value.defaults = defaults; try persist(value)
    }
    public func setHideContent(_ hidden: Bool) async throws {
        var value = settings; value.hideContent = hidden; try persist(value); purgeDelivered = true; await refresh()
    }
    public func removeOverride(identity: ReminderIdentity, anchor: OccurrenceAnchor) async throws {
        var value = settings; value.rules.removeOverride(identity: identity, anchor: anchor); try persist(value); await refresh()
    }
    public func snapshot(for event: EventOccurrence) -> ReminderDeliverySnapshot {
        if let value = eventSnapshots[event.id] { return value }
        guard let rule = settings.rules.resolve(event: event, context: context) else { return ReminderDeliverySnapshot(desiredEnabled: false, state: .noFuture) }
        return snapshots[rule.id] ?? ReminderDeliverySnapshot(desiredEnabled: rule.enabled, state: .updating)
    }
    public func clickLink(token: String) -> ReminderLink? { settings.links[token] }
    public func requestPermission() async {
        do { try await backend.requestPermission(); permissionRequestError = nil }
        catch { permissionRequestError = "알림 권한을 요청하지 못했습니다. 다시 시도해 주세요." }
        await refresh()
    }
    public func retry() async {
        if storageError != nil {
            do { settings = try storage.load().validated(); storageError = nil } catch { /* Reconcile still removes untrusted app requests. */ }
        }
        await refresh()
    }
    public func updateContext(_ context: CalendarContext) async { self.context = context; await refresh() }
    public func refresh() async { await enqueueRefresh().value }
    private func enqueueRefresh() -> Task<Void, Never> {
        revision += 1
        if let worker { return worker }
        let task = Task { [weak self] in
            await self?.drain()
            self?.worker = nil
        }
        worker = task
        return task
    }
    private func drain() async {
        var processed = -1
        while processed != revision && !Task.isCancelled {
            processed = revision
            await reconcile(generation: processed)
        }
    }
    private struct OccurrenceKey: Hashable {
        let calendar: String
        let item: String
        let anchor: OccurrenceAnchor
        init(_ identity: ReminderIdentity, _ anchor: OccurrenceAnchor) {
            calendar = identity.calendarID; item = identity.confirmedSeriesKey ?? identity.localItemID; self.anchor = anchor
        }
        init(_ link: ReminderLink) { self.init(link.identity, link.anchor) }
    }
    private func effectiveRule(_ link: ReminderLink, in saved: ReminderSettings) -> ReminderRule? {
        if link.isRecurring { return saved.rules.resolve(identity: link.identity, anchor: link.anchor) }
        return saved.rules.rules.last { $0.scope == .thisOccurrence && $0.identity.matchesItem(link.identity) }
    }
    private func sanitized(_ request: ReminderRequest, hidden: Bool) -> ReminderRequest {
        hidden ? ReminderRequest(id: request.id, fireDate: request.fireDate, title: "일정 알림", body: "캘린더에서 일정을 확인하세요.", token: request.token) : request
    }
    private func reconcile(generation: Int) async {
        armTimer()
        let saved = settings
        eventSnapshots = [:]
        snapshots = Dictionary(uniqueKeysWithValues: saved.rules.rules.map { ($0.id, ReminderDeliverySnapshot(desiredEnabled: $0.enabled, state: .updating)) })
        let currentTime = now()
        let end = context.calendar.date(byAdding: .year, value: 1, to: currentTime) ?? currentTime.addingTimeInterval(365 * 86400)
        let interval = DateInterval(start: currentTime, end: end)
        await access.refresh(channel: .reminders, interval: interval)
        guard generation == revision else { return }
        let query = access.snapshot(for: .reminders)
        let pending = await backend.pending().filter { $0.id.hasPrefix(ReminderRequest.prefix) }
        let delivered = await backend.deliveredIdentifiers().filter { $0.hasPrefix(ReminderRequest.prefix) }
        permission = await backend.permission()
        guard generation == revision else { return }

        // Privacy and explicit intent are decidable without a successful query.
        // With unreadable correspondence no own request can be proven in scope;
        // remove own notifications, preserving the unreadable settings file.
        let cannotUseCalendar = ![.loaded, .failed, .loading].contains(query.state)
        if storageError != nil || cannotUseCalendar || !permission.canSchedule {
            await backend.remove(pending.map(\.id) + delivered)
            guard generation == revision else { return }
            for rule in saved.rules.rules {
                snapshots[rule.id]?.state = !rule.enabled ? .noFuture : !permission.canSchedule || query.state == .connectionRequired ? .permissionRequired : .noFuture
            }
            return
        }
        let allowedCalendars = query.state == .loaded ? access.effectiveSelectedCalendarIDs : access.selectedCalendarIDs
        func allowed(_ link: ReminderLink?, requestID: String) -> Bool {
            guard let link, let rule = effectiveRule(link, in: saved), rule.enabled,
                  allowedCalendars.contains(link.identity.calendarID) else { return false }
            return rule.triggers.contains { ReminderRequest.identifier(identity: link.identity, anchor: link.anchor, trigger: $0) == requestID }
        }
        let didPurge = purgeDelivered
        let rejectedPending = pending.filter { !allowed(saved.links[$0.token], requestID: $0.id) }
        let rejectedDelivered = delivered.filter { didPurge || !allowed(saved.links[String($0.dropFirst(ReminderRequest.prefix.count))], requestID: $0) }
        await backend.remove(rejectedPending.map(\.id) + rejectedDelivered + (didPurge ? pending.map(\.id) : []))
        guard generation == revision else { return }
        purgeDelivered = false
        let retained = pending.filter { allowed(saved.links[$0.token], requestID: $0.id) && $0.fireDate > currentTime }
        if query.state == .failed || query.state == .loading {
            // A hide change transforms known requests in place even when fresh
            // calendar data is unavailable; their saved times remain trustworthy.
            for old in retained {
                let request = sanitized(old, hidden: saved.hideContent)
                if didPurge || !old.matches(request) {
                    do { try await backend.add(request) } catch { await backend.remove([request.id]) }
                    if generation != revision { await backend.remove([request.id]); return }
                }
            }
            let evidence = await backend.pending()
            guard generation == revision else { return }
            for rule in saved.rules.rules {
                snapshots[rule.id]?.state = rule.enabled ? .failed : .noFuture
                snapshots[rule.id]?.scheduled = evidence.filter { request in
                    guard let link = saved.links[request.token] else { return false }
                    return effectiveRule(link, in: saved)?.id == rule.id && allowed(link, requestID: request.id)
                }.count
            }
            return
        }

        var events = query.events
        var unsafeRules: Set<UUID> = []
        var unsafeKeys: Set<OccurrenceKey> = []
        var failed: Set<UUID> = []
        var invalidKeys: Set<OccurrenceKey> = []
        for rule in saved.rules.rules where rule.enabled {
            if events.contains(where: { saved.rules.resolve(event: $0, context: context)?.id == rule.id }) { continue }
            let recurring = saved.recurringRules[rule.id] ?? (rule.identity.confirmedSeriesKey != nil)
            let result = await access.resolve(identity: rule.identity, anchor: rule.anchor, isRecurring: recurring, searchInterval: interval)
            guard generation == revision else { return }
            let key = OccurrenceKey(rule.identity, rule.anchor)
            switch result {
            case .found(let event): events.append(event)
            case .failed: failed.insert(rule.id)
            case .needsConfirmation: unsafeRules.insert(rule.id); unsafeKeys.insert(key)
            case .outsideQuery:
                if rule.scope == .thisOccurrence { unsafeRules.insert(rule.id); unsafeKeys.insert(key) }
            case .missing, .outsideSelectedScope, .connectionRequired: invalidKeys.insert(key)
            }
        }
        var desired: [String: ReminderRequest] = [:]
        var links = saved.links
        let knownKeys = Set(events.compactMap { event -> OccurrenceKey? in
            guard let anchor = event.reminderAnchor(context: context) else { return nil }
            return OccurrenceKey(event.reminderIdentity, anchor)
        })
        var unsafeEvents: Set<EventOccurrence.ID> = []
        for event in events {
            if event.isRecurring && event.originalOccurrence == nil {
                let applicable = saved.rules.rules.filter { $0.identity.matchesOccurrenceItem(event.reminderIdentity) && $0.enabled }
                guard !applicable.isEmpty else { continue }
                unsafeEvents.insert(event.id)
                for rule in applicable { unsafeRules.insert(rule.id) }
                // Unknown anchor cannot erase separately confirmed A/B occurrences.
                for link in saved.links.values where link.identity.matchesOccurrenceItem(event.reminderIdentity) && !knownKeys.contains(OccurrenceKey(link)) { unsafeKeys.insert(OccurrenceKey(link)) }
                continue
            }
            guard let rule = saved.rules.resolve(event: event, context: context), rule.enabled else { continue }
            guard let anchor = event.isRecurring ? event.reminderAnchor(context: context) : Optional(rule.anchor) else { continue }
            let key = OccurrenceKey(event.reminderIdentity, anchor)
            switch ReminderCalculator.calculate(rule: rule, event: event, now: currentTime, context: context) {
            case .needsFormatConfirmation, .invalidDate:
                unsafeRules.insert(rule.id); unsafeKeys.insert(key); unsafeEvents.insert(event.id)
            case .scheduled:
                for trigger in rule.triggers {
                    guard let single = try? ReminderRule(identity: rule.identity, anchor: rule.anchor, scope: rule.scope, format: rule.format, enabled: true, triggers: [trigger]), case .scheduled(let dates) = ReminderCalculator.calculate(rule: single, event: event, now: currentTime, context: context), let date = dates.first else { continue }
                    let id = ReminderRequest.identifier(identity: event.reminderIdentity, anchor: anchor, trigger: trigger)
                    let token = String(id.dropFirst(ReminderRequest.prefix.count))
                    links[token] = ReminderLink(identity: event.reminderIdentity, anchor: anchor, isRecurring: event.isRecurring, ruleID: rule.id)
                    let formatter = DateFormatter(); formatter.timeZone = context.calendar.timeZone; formatter.dateStyle = .medium; formatter.timeStyle = event.isAllDay ? .none : .short
                    desired[id] = sanitized(ReminderRequest(id: id, fireDate: date, title: event.title, body: formatter.string(from: event.start), token: token), hidden: saved.hideContent)
                }
            }
        }
        for request in retained {
            guard let link = saved.links[request.token], let rule = effectiveRule(link, in: saved), failed.contains(rule.id) else { continue }
            desired[request.id] = sanitized(request, hidden: saved.hideContent)
        }

        // Delivered occurrences may be outside the future query, and an enabled
        // parent rule says nothing about an occurrence override or deletion.
        var obsoleteDelivered: [String] = []
        var resolvedDelivered: [OccurrenceKey: CalendarEventResolution] = [:]
        for id in delivered where !rejectedDelivered.contains(id) {
            let token = String(id.dropFirst(ReminderRequest.prefix.count))
            guard let link = saved.links[token], let rule = effectiveRule(link, in: saved), allowed(link, requestID: id) else { obsoleteDelivered.append(id); continue }
            let key = OccurrenceKey(link)
            if unsafeKeys.contains(key) || invalidKeys.contains(key) { obsoleteDelivered.append(id); continue }
            let result: CalendarEventResolution
            if let cached = resolvedDelivered[key] { result = cached }
            else {
                result = await access.resolve(identity: link.identity, anchor: link.anchor, isRecurring: link.isRecurring, searchInterval: interval)
                guard generation == revision else { return }
                resolvedDelivered[key] = result
            }
            switch result {
            case .found(let event):
                if (rule.format == .allDay) != event.isAllDay {
                    obsoleteDelivered.append(id); unsafeRules.insert(rule.id); unsafeKeys.insert(key)
                    eventSnapshots[event.id] = ReminderDeliverySnapshot(desiredEnabled: true, state: .needsConfirmation)
                }
            case .needsConfirmation, .outsideQuery:
                obsoleteDelivered.append(id); unsafeRules.insert(rule.id); unsafeKeys.insert(key)
            case .missing, .outsideSelectedScope, .connectionRequired: obsoleteDelivered.append(id)
            case .failed: break
            }
        }
        desired = desired.filter { entry in
            guard let link = links[entry.value.token] else { return false }
            return !unsafeKeys.contains(OccurrenceKey(link)) && !invalidKeys.contains(OccurrenceKey(link))
        }
        let ordered = desired.values.sorted { $0.fireDate == $1.fireDate ? $0.id < $1.id : $0.fireDate < $1.fireDate }
        let selected = Array(ordered.prefix(budget))
        let selectedIDs = Set(selected.map(\.id))

        guard generation == revision else { return }
        await backend.remove(pending.map(\.id).filter { !selectedIDs.contains($0) } + obsoleteDelivered)
        guard generation == revision else { return }
        var next = settings; next.links = links
        do { try persist(next) } catch { for rule in saved.rules.rules { snapshots[rule.id]?.state = .failed }; return }
        var addFailures: Set<String> = []
        for request in selected {
            guard generation == revision else { return }
            if pending.contains(where: { $0.matches(request) }) && !didPurge { continue }
            do { try await backend.add(request) } catch { addFailures.insert(request.id) }
            if generation != revision { await backend.remove([request.id]); return }
        }
        let evidence = await backend.pending()
        guard generation == revision else { return }
        let actual = Set(selected.filter { request in evidence.contains { $0.matches(request) } }.map(\.id))
        func delivery(_ requests: [ReminderRequest]) -> ReminderDeliveryState {
            let count = requests.filter { actual.contains($0.id) }.count
            if requests.contains(where: { addFailures.contains($0.id) }) || count < requests.count { return count > 0 || requests.contains(where: { !selectedIDs.contains($0.id) }) ? .partial : .failed }
            return count > 0 ? .scheduled : .noFuture
        }
        for rule in saved.rules.rules {
            let requests = ordered.filter { links[$0.token].flatMap { effectiveRule($0, in: saved) }?.id == rule.id }
            snapshots[rule.id] = ReminderDeliverySnapshot(desiredEnabled: rule.enabled, state: unsafeRules.contains(rule.id) ? .needsConfirmation : failed.contains(rule.id) ? .failed : delivery(requests), scheduled: requests.filter { actual.contains($0.id) }.count, deferred: requests.filter { !selectedIDs.contains($0.id) }.count)
        }
        for event in events {
            if unsafeEvents.contains(event.id) { eventSnapshots[event.id] = ReminderDeliverySnapshot(desiredEnabled: true, state: .needsConfirmation); continue }
            guard let rule = saved.rules.resolve(event: event, context: context) else { continue }
            let anchor = event.isRecurring ? event.reminderAnchor(context: context) : rule.anchor
            if let anchor, unsafeKeys.contains(OccurrenceKey(event.reminderIdentity, anchor)) {
                eventSnapshots[event.id] = ReminderDeliverySnapshot(desiredEnabled: rule.enabled, state: .needsConfirmation)
                continue
            }
            let requests = ordered.filter { request in
                guard let link = links[request.token] else { return false }
                return link.identity.matchesOccurrenceItem(event.reminderIdentity) && link.anchor == anchor
            }
            eventSnapshots[event.id] = ReminderDeliverySnapshot(desiredEnabled: rule.enabled, state: failed.contains(rule.id) ? .failed : delivery(requests), scheduled: requests.filter { actual.contains($0.id) }.count, deferred: requests.filter { !selectedIDs.contains($0.id) }.count)
        }
        if scheduled > 0 { lastScheduled = currentTime }
        if let last = selected.last { armTimer(delay: last.fireDate.timeIntervalSince(now()) - 60) }
    }
}
