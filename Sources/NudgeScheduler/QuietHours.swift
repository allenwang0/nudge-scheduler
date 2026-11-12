import Foundation

/// A daily window when nothing is delivered, in minutes after local midnight.
/// The window may wrap midnight (22:00 to 08:00). Equal start and end means no quiet hours.
public struct QuietHours: Hashable, Sendable, Codable {
    public let startMinute: Int
    public let endMinute: Int

    public enum Error: Swift.Error, Equatable {
        case minuteOutOfRange(Int)
        case allowedWindowTooShort(minutes: Int)
    }

    /// Deliveries need some room every day; quiet hours longer than 23 hours are rejected.
    public static let minimumAllowedMinutes = 60

    public static let none = QuietHours(validStart: 0, end: 0)

    public init(startMinute: Int, endMinute: Int) throws {
        for m in [startMinute, endMinute] where !(0..<1440).contains(m) {
            throw Error.minuteOutOfRange(m)
        }
        let allowed = startMinute == endMinute ? 1440 : (startMinute - endMinute + 1440) % 1440
        guard allowed >= Self.minimumAllowedMinutes else {
            throw Error.allowedWindowTooShort(minutes: allowed)
        }
        self.init(validStart: startMinute, end: endMinute)
    }

    public init(startHour: Int, endHour: Int) throws {
        try self.init(startMinute: startHour * 60, endMinute: endHour * 60)
    }

    private init(validStart: Int, end: Int) {
        startMinute = validStart
        endMinute = end
    }

    public var isEmpty: Bool { startMinute == endMinute }

    public var wrapsMidnight: Bool { startMinute > endMinute }

    public func contains(minuteOfDay m: Int) -> Bool {
        if isEmpty { return false }
        if wrapsMidnight { return m >= startMinute || m < endMinute }
        return m >= startMinute && m < endMinute
    }

    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return contains(minuteOfDay: c.hour! * 60 + c.minute!)
    }
}
