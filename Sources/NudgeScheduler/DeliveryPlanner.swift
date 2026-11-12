import Foundation

/// Times a day's nudges inside the next allowed window, outside quiet hours.
public enum DeliveryPlanner {
    /// Nothing is delivered sooner than this after `now`.
    public static let leadMinutes = 15
    /// Preferred minimum gap between deliveries. A window too short for this is skipped
    /// unless it is a whole window that still fits one minute per nudge.
    public static let preferredSpacingMinutes = 15
    public static let maxCount = 60

    /// Returns `count` strictly increasing dates, all later than `now`, none inside quiet hours.
    /// Allowed windows run from the end of quiet hours to the next start. With no quiet hours,
    /// each calendar day is one window.
    public static func dates(count: Int, now: Date, quietHours: QuietHours, calendar: Calendar) -> [Date] {
        precondition((0...maxCount).contains(count), "count must be in 0...\(maxCount)")
        guard count > 0 else { return [] }
        let earliest = ceilToMinute(now.addingTimeInterval(TimeInterval(leadMinutes * 60)))
        let today = calendar.startOfDay(for: now)

        for offset in -1...3 {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            guard let (windowStart, windowEnd) = window(on: day, quietHours: quietHours, calendar: calendar)
            else { continue }
            let start = max(windowStart, earliest)
            let available = Int(windowEnd.timeIntervalSince(start)) / 60
            let fullLength = Int(windowEnd.timeIntervalSince(windowStart)) / 60
            let roomy = available >= count * preferredSpacingMinutes
            let wholeShortWindow = start == windowStart && fullLength < count * preferredSpacingMinutes
            guard roomy || (wholeShortWindow && available >= count) else { continue }
            let step = available / count
            return (0..<count).map { start.addingTimeInterval(TimeInterval($0 * step * 60)) }
        }
        preconditionFailure("an allowed window of at least one hour exists every day")
    }

    static func window(on day: Date, quietHours: QuietHours, calendar: Calendar) -> (Date, Date)? {
        if quietHours.isEmpty {
            return (day, calendar.date(byAdding: .day, value: 1, to: day)!)
        }
        guard let start = time(quietHours.endMinute, on: day, calendar: calendar) else { return nil }
        let endDay = quietHours.wrapsMidnight ? day : calendar.date(byAdding: .day, value: 1, to: day)!
        guard let end = time(quietHours.startMinute, on: endDay, calendar: calendar) else { return nil }
        return (start, end)
    }

    private static func time(_ minuteOfDay: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: day)
    }

    private static func ceilToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60)
    }
}
