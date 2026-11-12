import Foundation

public struct NudgeSettings: Hashable, Sendable {
    public static let capRange = 1...10

    /// The one daily cap. Nothing else trims the list.
    public let dailyCap: Int
    public let quietHours: QuietHours
    /// Calendar weekday (1 = Sunday) for the weekly check-in nudge, or nil for none.
    public let checkInWeekday: Int?

    public enum Error: Swift.Error, Equatable {
        case capOutOfRange(Int)
        case weekdayOutOfRange(Int)
    }

    public init(dailyCap: Int = 3, quietHours: QuietHours, checkInWeekday: Int? = nil) throws {
        guard Self.capRange.contains(dailyCap) else { throw Error.capOutOfRange(dailyCap) }
        if let w = checkInWeekday, !(1...7).contains(w) { throw Error.weekdayOutOfRange(w) }
        self.dailyCap = dailyCap
        self.quietHours = quietHours
        self.checkInWeekday = checkInWeekday
    }
}

/// Decides which nudges to surface on a given day. Pure: no clock, no storage.
public struct NudgeEngine: Sendable {
    public let settings: NudgeSettings

    public enum Priority {
        public static let birthdayToday = 100
        public static let birthdayTomorrow = 95
        public static let birthdayInAWeek = 80
        public static let driftBase = 50
        /// Drift priority grows one point per overdue day up to this many days, so it peaks at 90.
        public static let driftMaxBonus = 40
        public static let checkIn = 40
    }

    public init(settings: NudgeSettings) {
        self.settings = settings
    }

    public func nudges(
        for contacts: [Contact], now: Date, calendar: Calendar, snoozes: SnoozeBook = SnoozeBook()
    ) -> [Nudge] {
        var best: [ContactID: Nudge] = [:]
        for contact in contacts where !contact.paused && !snoozes.isSnoozed(contact.id, at: now) {
            for candidate in Self.candidates(for: contact, now: now, calendar: calendar) {
                if let current = best[contact.id], !Self.ordered(candidate, before: current) {
                    continue
                }
                best[contact.id] = candidate
            }
        }
        var result = Array(best.values)
        if let weekday = settings.checkInWeekday, calendar.component(.weekday, from: now) == weekday {
            result.append(Nudge(kind: .checkIn, contact: nil, ring: nil, priority: Priority.checkIn))
        }
        result.sort(by: Self.ordered)
        return Array(result.prefix(settings.dailyCap))
    }

    static func candidates(for contact: Contact, now: Date, calendar: Calendar) -> [Nudge] {
        var out: [Nudge] = []
        if let birthday = contact.birthday {
            let days = Self.daysUntil(birthday, now: now, calendar: calendar)
            let priority: Int? =
                switch days {
                case 0: Priority.birthdayToday
                case 1: Priority.birthdayTomorrow
                case 7: Priority.birthdayInAWeek
                default: nil
                }
            if let priority {
                out.append(
                    Nudge(kind: .birthday(daysUntil: days), contact: contact.id, ring: contact.ring, priority: priority))
            }
        }
        if let overdue = daysOverdue(contact, now: now, calendar: calendar), overdue >= 0 {
            let priority = Priority.driftBase + min(overdue, Priority.driftMaxBonus)
            out.append(
                Nudge(kind: .drift(daysOverdue: overdue), contact: contact.id, ring: contact.ring, priority: priority))
        }
        return out
    }

    /// Total order: priority, then kind, then ring, then contact ID. Equal inputs give equal output.
    static func ordered(_ a: Nudge, before b: Nudge) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        if a.kind.rank != b.kind.rank { return a.kind.rank < b.kind.rank }
        let ra = a.ring?.rawValue ?? Int.max
        let rb = b.ring?.rawValue ?? Int.max
        if ra != rb { return ra < rb }
        return (a.contact?.rawValue ?? "") < (b.contact?.rawValue ?? "")
    }

    /// Whole calendar days from `from` to `to`, counted between local midnights.
    public static func calendarDays(from: Date, to: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day!
    }

    /// Days since last contact (or since the contact was added), never negative.
    public static func daysSinceContact(_ contact: Contact, now: Date, calendar: Calendar) -> Int {
        max(0, calendarDays(from: contact.lastContact ?? contact.addedAt, to: now, calendar: calendar))
    }

    /// Days past the cadence (0 on the day it is reached), negative before it, nil for no cadence.
    public static func daysOverdue(_ contact: Contact, now: Date, calendar: Calendar) -> Int? {
        guard let cadence = contact.effectiveCadenceDays else { return nil }
        return daysSinceContact(contact, now: now, calendar: calendar) - cadence
    }

    /// Days until the next observed birthday, 0 on the day. Feb 29 is observed on Feb 28 in common years.
    public static func daysUntil(_ birthday: MonthDay, now: Date, calendar: Calendar) -> Int {
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: today)
        for y in [year, year + 1] {
            let observed = observedDate(birthday, year: y, calendar: calendar)
            if observed >= today {
                return calendarDays(from: today, to: observed, calendar: calendar)
            }
        }
        preconditionFailure("a birthday always occurs within the next two calendar years")
    }

    static func observedDate(_ birthday: MonthDay, year: Int, calendar: Calendar) -> Date {
        var day = birthday.day
        if birthday.month == 2 && birthday.day == 29 && !isLeapYear(year, calendar: calendar) {
            day = 28
        }
        return calendar.date(from: DateComponents(year: year, month: birthday.month, day: day))!
    }

    static func isLeapYear(_ year: Int, calendar: Calendar) -> Bool {
        let feb = calendar.date(from: DateComponents(year: year, month: 2, day: 1))!
        return calendar.range(of: .day, in: .month, for: feb)!.count == 29
    }
}
