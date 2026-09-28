import Foundation

public struct CivilDate: Codable, Hashable, Sendable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int
    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }
    public init(date: Date, context: CalendarContext) {
        let c = context.calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day) }
}
public enum OccurrenceAnchor: Codable, Hashable, Sendable {
    case timed(Date)
    case civil(CivilDate)
    /// Total order for display identity; rule comparisons use only like anchor kinds.
    public func sortsBefore(_ other: Self) -> Bool {
        if case .timed = self, case .civil = other { return true }
        return isBefore(other)
    }
    public func isBefore(_ other: Self) -> Bool {
        switch (self, other) {
        case let (.timed(a), .timed(b)): return a < b
        case let (.civil(a), .civil(b)): return a < b
        default: return false
        }
    }
}
public struct ReminderIdentity: Codable, Hashable, Sendable {
    public let calendarID: String
    public let localItemID: String
    public let externalID: String?
    public let confirmedSeriesKey: String?
    public init(calendarID: String, localItemID: String, externalID: String? = nil, confirmedSeriesKey: String? = nil) {
        self.calendarID = calendarID; self.localItemID = localItemID; self.externalID = externalID; self.confirmedSeriesKey = confirmedSeriesKey
    }
    public func matchesItem(_ other: Self) -> Bool { calendarID == other.calendarID && localItemID == other.localItemID }
    public func matchesOccurrenceItem(_ other: Self) -> Bool { matchesItem(other) || matchesSeries(other) }
    public func matchesSeries(_ other: Self) -> Bool { calendarID == other.calendarID && confirmedSeriesKey != nil && confirmedSeriesKey == other.confirmedSeriesKey }
}
/// The adapter must explicitly confirm an identity; ambiguous sync/remap results never schedule.
public enum ReminderIdentityResolution: Equatable, Sendable { case confirmed(ReminderIdentity), uncertain, missing }
public enum ReminderScope: String, Codable, Sendable { case thisOccurrence, thisAndFuture }
public enum ReminderFormat: String, Codable, Sendable { case timed, allDay }

public struct ReminderTrigger: Codable, Hashable, Sendable {
    public let format: ReminderFormat
    public let minutesBefore: Int
    public let daysBefore: Int
    public let hour: Int
    public let minute: Int
    private init(format: ReminderFormat, minutesBefore: Int = 0, daysBefore: Int = 0, hour: Int = 0, minute: Int = 0) {
        self.format = format; self.minutesBefore = minutesBefore; self.daysBefore = daysBefore; self.hour = hour; self.minute = minute
    }
    public static func timed(hours: Int, minutes: Int) throws -> Self {
        let (h, overflow) = hours.multipliedReportingOverflow(by: 60)
        let (total, additionOverflow) = h.addingReportingOverflow(minutes)
        guard hours >= 0, (0...59).contains(minutes), !overflow, !additionOverflow, total >= 1, total <= Int.max / 60 else { throw CalendarValueError.invalidTrigger }
        return Self(format: .timed, minutesBefore: total)
    }
    public static func allDay(daysBefore: Int, hour: Int, minute: Int) throws -> Self {
        guard daysBefore >= 0, daysBefore <= Int.max / 86_400, (0...23).contains(hour), (0...59).contains(minute) else { throw CalendarValueError.invalidTrigger }
        return Self(format: .allDay, daysBefore: daysBefore, hour: hour, minute: minute)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decode(ReminderFormat.self, forKey: .format)
        if format == .timed {
            let total = try c.decode(Int.self, forKey: .minutesBefore)
            self = try .timed(hours: total / 60, minutes: total % 60)
        } else {
            self = try .allDay(daysBefore: c.decode(Int.self, forKey: .daysBefore), hour: c.decode(Int.self, forKey: .hour), minute: c.decode(Int.self, forKey: .minute))
        }
    }
}
public struct ReminderRule: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let identity: ReminderIdentity
    public let anchor: OccurrenceAnchor
    public let scope: ReminderScope
    public let format: ReminderFormat
    public let enabled: Bool
    public let triggers: [ReminderTrigger]
    public init(id: UUID = UUID(), identity: ReminderIdentity, anchor: OccurrenceAnchor, scope: ReminderScope, format: ReminderFormat, enabled: Bool, triggers: [ReminderTrigger]) throws {
        guard scope != .thisAndFuture || identity.confirmedSeriesKey != nil else { throw CalendarValueError.unconfirmedSeries }
        // The anchor describes the original occurrence. Its kind stays unchanged
        // even after the user confirms a timed/all-day format conversion.
        switch anchor {
        case .timed(let date):
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw CalendarValueError.invalidAnchor }
        case .civil(let civil):
            let calendar = CalendarContext(timeZone: TimeZone(secondsFromGMT: 0)!).calendar
            guard let date = calendar.date(from: DateComponents(year: civil.year, month: civil.month, day: civil.day)), CivilDate(date: date, context: CalendarContext(timeZone: calendar.timeZone)) == civil else { throw CalendarValueError.invalidAnchor }
        }
        guard triggers.allSatisfy({ $0.format == format }) else { throw CalendarValueError.formatMismatch }
        let unique = Set(triggers).sorted {
            if $0.minutesBefore != $1.minutesBefore { return $0.minutesBefore > $1.minutesBefore }
            if $0.daysBefore != $1.daysBefore { return $0.daysBefore > $1.daysBefore }
            if $0.hour != $1.hour { return $0.hour < $1.hour }; return $0.minute < $1.minute
        }
        guard !enabled || !unique.isEmpty else { throw CalendarValueError.emptyTriggers }
        self.id = id; self.identity = identity; self.anchor = anchor; self.scope = scope; self.format = format; self.enabled = enabled; self.triggers = enabled ? unique : []
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), identity: c.decode(ReminderIdentity.self, forKey: .identity), anchor: c.decode(OccurrenceAnchor.self, forKey: .anchor), scope: c.decode(ReminderScope.self, forKey: .scope), format: c.decode(ReminderFormat.self, forKey: .format), enabled: c.decode(Bool.self, forKey: .enabled), triggers: c.decode([ReminderTrigger].self, forKey: .triggers))
    }
}
public struct ReminderDefaults: Codable, Equatable, Sendable {
    public var timed: [ReminderTrigger]
    public var allDay: [ReminderTrigger]
    public init(timed: [ReminderTrigger] = [try! .timed(hours: 1, minutes: 0), try! .timed(hours: 0, minutes: 10)], allDay: [ReminderTrigger] = [try! .allDay(daysBefore: 1, hour: 21, minute: 0)]) { self.timed = timed; self.allDay = allDay }
    public func rule(identity: ReminderIdentity, anchor: OccurrenceAnchor, scope: ReminderScope, format: ReminderFormat) throws -> ReminderRule {
        try ReminderRule(identity: identity, anchor: anchor, scope: scope, format: format, enabled: true, triggers: format == .timed ? timed : allDay)
    }
}
public struct ReminderRules: Codable, Equatable, Sendable {
    public private(set) var rules: [ReminderRule]
    public init(rules: [ReminderRule] = []) { self.rules = rules }
    public mutating func replace(with rule: ReminderRule) throws {
        rules.removeAll { old in
            guard old.scope == rule.scope else { return false }
            if rule.scope == .thisOccurrence { return old.identity.matchesOccurrenceItem(rule.identity) && old.anchor == rule.anchor }
            return old.identity.matchesSeries(rule.identity) && (old.anchor == rule.anchor || rule.anchor.isBefore(old.anchor))
        }
        rules.append(rule)
    }
    public mutating func removeOverride(identity: ReminderIdentity, anchor: OccurrenceAnchor) {
        rules.removeAll { $0.scope == .thisOccurrence && $0.identity.matchesOccurrenceItem(identity) && $0.anchor == anchor }
    }
    /// Nonrecurring item moves retain their saved rule/anchor. Recurrences require the
    /// original occurrence anchor, never the edited start or a title comparison.
    public func resolve(event: EventOccurrence, context: CalendarContext) -> ReminderRule? {
        if !event.isRecurring {
            return rules.last { $0.scope == .thisOccurrence && $0.identity.matchesItem(event.reminderIdentity) }
        }
        if let override = rules.last(where: { $0.scope == .thisOccurrence && $0.identity.matchesOccurrenceItem(event.reminderIdentity) && event.matchesOriginalAnchor($0.anchor) }) { return override }
        guard !needsIdentityConfirmation(event: event) else { return nil }
        return rules.filter { rule in
            guard rule.scope == .thisAndFuture, rule.identity.matchesSeries(event.reminderIdentity),
                  let anchor = event.originalAnchor(matching: rule.anchor) else { return false }
            return rule.anchor == anchor || rule.anchor.isBefore(anchor)
        }.max { $0.anchor.isBefore($1.anchor) }
    }
    public mutating func removeOverride(event: EventOccurrence, context: CalendarContext) {
        if !event.isRecurring {
            rules.removeAll { $0.scope == .thisOccurrence && $0.identity.matchesItem(event.reminderIdentity) }
        } else if let rule = resolve(event: event, context: context), rule.scope == .thisOccurrence {
            removeOverride(identity: event.reminderIdentity, anchor: rule.anchor)
        }
    }
    public func needsIdentityConfirmation(event: EventOccurrence) -> Bool {
        // An exact override wins before a less precise series/civil rule.
        if rules.contains(where: { $0.scope == .thisOccurrence && $0.identity.matchesOccurrenceItem(event.reminderIdentity) && event.matchesOriginalAnchor($0.anchor) }) { return false }
        return rules.contains { rule in
            guard rule.identity.matchesOccurrenceItem(event.reminderIdentity),
                  let anchor = event.originalAnchor(matching: rule.anchor), event.ambiguousOriginalOccurrences.contains(anchor) else { return false }
            return rule.scope == .thisOccurrence ? rule.anchor == anchor : rule.identity.matchesSeries(event.reminderIdentity) && (rule.anchor == anchor || rule.anchor.isBefore(anchor))
        }
    }
    public func resolve(identity: ReminderIdentity, anchor: OccurrenceAnchor) -> ReminderRule? {
        if let override = rules.last(where: { $0.scope == .thisOccurrence && $0.identity.matchesOccurrenceItem(identity) && $0.anchor == anchor }) { return override }
        return rules.filter { $0.scope == .thisAndFuture && $0.identity.matchesSeries(identity) && ($0.anchor == anchor || $0.anchor.isBefore(anchor)) }.max { $0.anchor.isBefore($1.anchor) }
    }
}
public enum ReminderCalculation: Equatable, Sendable { case scheduled([Date]), needsFormatConfirmation, invalidDate }
public enum ReminderCalculator {
    /// Identity matching is performed by the caller before calculation. Never uses titles.
    public static func calculate(rule: ReminderRule, event: EventOccurrence, now: Date, context: CalendarContext) -> ReminderCalculation {
        guard rule.enabled else { return .scheduled([]) }
        guard (rule.format == .allDay) == event.isAllDay else { return .needsFormatConfirmation }
        var dates: [Date] = []
        for trigger in rule.triggers {
            let fire: Date
            if trigger.format == .timed {
                fire = event.start.addingTimeInterval(-Double(trigger.minutesBefore) * 60)
            } else {
                let firstDay = context.calendar.startOfDay(for: event.start)
                guard let prior = context.calendar.date(byAdding: .day, value: -trigger.daysBefore, to: firstDay) else { return .invalidDate }
                let day = context.calendar.startOfDay(for: prior)
                guard let candidate = context.calendar.date(bySettingHour: trigger.hour, minute: trigger.minute, second: 0, of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward), context.calendar.isDate(candidate, inSameDayAs: day) else { return .invalidDate }
                fire = candidate
            }
            guard fire.timeIntervalSinceReferenceDate.isFinite else { return .invalidDate }
            if fire > now { dates.append(fire) }
        }
        return .scheduled(Array(Set(dates)).sorted())
    }
}
