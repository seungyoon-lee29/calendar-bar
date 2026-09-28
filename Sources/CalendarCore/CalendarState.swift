import Foundation

public struct MonthGrid: Equatable, Sendable {
    public let monthStart: Date
    public let days: [Date]
    /// End is exclusive, including every adjacent-month cell shown in the grid.
    public let queryInterval: DateInterval
}

public struct CalendarContext: Equatable, Sendable {
    public let calendar: Calendar

    public init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 1
        self.calendar = calendar
    }

    public func monthGrid(containing date: Date) -> MonthGrid {
        let month = calendar.dateInterval(of: .month, for: date)!
        let offset = calendar.component(.weekday, from: month.start) - 1
        let start = calendar.date(byAdding: .day, value: -offset, to: month.start)!
        let monthDays = calendar.range(of: .day, in: .month, for: date)!.count
        let count = ((offset + monthDays + 6) / 7) * 7
        let days = (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start)! }
        let end = calendar.date(byAdding: .day, value: count, to: start)!
        return MonthGrid(monthStart: month.start, days: days, queryInterval: DateInterval(start: start, end: end))
    }
}

public struct CalendarState: Equatable, Sendable {
    public private(set) var context: CalendarContext
    public private(set) var displayedMonth: Date
    public private(set) var selectedDate: Date
    public private(set) var today: Date
    public var grid: MonthGrid { context.monthGrid(containing: displayedMonth) }

    public init(now: Date = Date(), timeZone: TimeZone = .current) {
        let context = CalendarContext(timeZone: timeZone)
        self.context = context
        selectedDate = context.calendar.startOfDay(for: now)
        today = selectedDate
        displayedMonth = context.calendar.dateInterval(of: .month, for: now)!.start
    }

    public mutating func open(at now: Date = Date()) {
        refreshToday(at: now)
        select(today)
    }

    public mutating func select(_ date: Date) {
        selectedDate = context.calendar.startOfDay(for: date)
        displayedMonth = context.calendar.dateInterval(of: .month, for: date)!.start
    }

    public mutating func moveMonth(by amount: Int) {
        let calendar = context.calendar
        guard let target = calendar.date(byAdding: .month, value: amount, to: displayedMonth),
              let range = calendar.range(of: .day, in: .month, for: target) else { return }
        let day = min(calendar.component(.day, from: selectedDate), range.count)
        select(calendar.date(byAdding: .day, value: day - 1, to: target)!)
    }

    /// Preserve the browsed civil date when the system time zone changes.
    public mutating func refreshToday(at now: Date = Date(), timeZone: TimeZone? = nil) {
        if let timeZone, timeZone != context.calendar.timeZone {
            let selected = context.calendar.dateComponents([.era, .year, .month, .day], from: selectedDate)
            context = CalendarContext(timeZone: timeZone)
            select(context.calendar.date(from: selected)!)
        }
        today = context.calendar.startOfDay(for: now)
    }
}
