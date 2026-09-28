import Foundation

public enum StatusDate {
    public static func day(at date: Date, timeZone: TimeZone = .current) -> Int {
        calendar(timeZone).component(.day, from: date)
    }

    public static func nextMidnight(after date: Date, timeZone: TimeZone = .current) -> Date {
        let calendar = calendar(timeZone)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        return calendar.startOfDay(for: nextDay)
    }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
