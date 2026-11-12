import Foundation
import Testing
@testable import NudgeScheduler

/// Regression tests for the rules the source app got wrong. Each names the failing scenario.
struct EngineTests {
    let now = date(2026, 6, 10)

    @Test("The configured cap is the only cap: cap 5 with 5 overdue contacts yields 5, not 3")
    func capIsHonored() {
        let contacts = (1...5).map { overdueContact("c\($0)", daysSince: 30, now: now) }
        let engine = NudgeEngine(settings: settings(cap: 5))
        #expect(engine.nudges(for: contacts, now: now, calendar: losAngeles).count == 5)
    }

    @Test("Caps outside 1...10 are rejected instead of silently clamped")
    func capValidated() {
        let quiet = QuietHours.none
        #expect(throws: NudgeSettings.Error.capOutOfRange(0)) { try NudgeSettings(dailyCap: 0, quietHours: quiet) }
        #expect(throws: NudgeSettings.Error.capOutOfRange(11)) { try NudgeSettings(dailyCap: 11, quietHours: quiet) }
    }

    @Test("Drift priority reaches 90 at 40 days overdue, so the ceiling is real and birthdays still win")
    func driftPriorityPeak() {
        func priority(overdue: Int) -> Int {
            let c = overdueContact("c", ring: .inner, daysSince: 10 + overdue, now: now)
            return NudgeEngine.candidates(for: c, now: now, calendar: losAngeles)[0].priority
        }
        #expect(priority(overdue: 0) == 50)
        #expect(priority(overdue: 39) == 89)
        #expect(priority(overdue: 40) == 90)
        #expect(priority(overdue: 400) == 90)
        #expect(NudgeEngine.Priority.birthdayTomorrow > priority(overdue: 400))
    }

    @Test("A contact is nudged on the day the cadence is reached, not before")
    func cadenceBoundary() {
        let engine = NudgeEngine(settings: settings())
        #expect(engine.nudges(for: [overdueContact("a", ring: .close, daysSince: 19, now: now)], now: now, calendar: losAngeles).isEmpty)
        #expect(engine.nudges(for: [overdueContact("a", ring: .close, daysSince: 20, now: now)], now: now, calendar: losAngeles).count == 1)
    }

    @Test("Snoozes are per ID: snoozing one of two contacts leaves the other nudged")
    func snoozeByID() {
        let a = overdueContact("a", daysSince: 30, now: now)
        let b = overdueContact("b", daysSince: 30, now: now)
        var book = SnoozeBook()
        book.snooze(a.id, now: now, calendar: losAngeles)
        let ids = NudgeEngine(settings: settings()).nudges(for: [a, b], now: now, calendar: losAngeles, snoozes: book)
            .map(\.contact)
        #expect(ids == [b.id])
    }

    @Test("A 7-day snooze has expired 8 days later and is pruned")
    func snoozeExpires() {
        let a = overdueContact("a", daysSince: 30, now: now)
        var book = SnoozeBook()
        let snoozedAt = losAngeles.date(byAdding: .day, value: -8, to: now)!
        book.snooze(a.id, now: snoozedAt, calendar: losAngeles)
        #expect(!book.isSnoozed(a.id, at: now))
        #expect(NudgeEngine(settings: settings()).nudges(for: [a], now: now, calendar: losAngeles, snoozes: book).count == 1)
        book.prune(now: now)
        #expect(book.expiries.isEmpty)
    }

    @Test("Paused contacts are never nudged")
    func paused() {
        var a = overdueContact("a", daysSince: 30, now: now)
        a.paused = true
        #expect(NudgeEngine(settings: settings()).nudges(for: [a], now: now, calendar: losAngeles).isEmpty)
    }

    @Test("Feb 29 birthdays are observed on Feb 28 in common years and on Feb 29 in leap years")
    func leapDay() {
        let leap = MonthDay(month: 2, day: 29)!
        #expect(NudgeEngine.daysUntil(leap, now: date(2027, 2, 28), calendar: losAngeles) == 0)
        #expect(NudgeEngine.daysUntil(leap, now: date(2028, 2, 28), calendar: losAngeles) == 1)
        #expect(NudgeEngine.daysUntil(leap, now: date(2028, 2, 29), calendar: losAngeles) == 0)
        #expect(NudgeEngine.daysUntil(leap, now: date(2027, 3, 1), calendar: losAngeles) == 365)
    }

    @Test("Impossible birthdays are rejected")
    func monthDayValidation() {
        #expect(MonthDay(month: 4, day: 31) == nil)
        #expect(MonthDay(month: 13, day: 1) == nil)
    }

    @Test("One contact gets one slot: birthday and drift on the same day yields only the birthday")
    func onePerContact() {
        var a = overdueContact("a", daysSince: 60, now: now)
        a.birthday = MonthDay(month: 6, day: 10)
        let others = (1...2).map { overdueContact("o\($0)", daysSince: 25, now: now) }
        let result = NudgeEngine(settings: settings(cap: 3)).nudges(for: [a] + others, now: now, calendar: losAngeles)
        #expect(result.count == 3)
        #expect(result[0] == Nudge(kind: .birthday(daysUntil: 0), contact: a.id, ring: .close, priority: 100))
        #expect(Set(result.compactMap(\.contact)).count == 3)
    }

    @Test("Equal priorities break ties by ring, so an inner contact outranks an equally overdue outer one")
    func ringTiebreak() {
        let inner = overdueContact("z", ring: .inner, daysSince: 15, now: now)
        let outer = overdueContact("a", ring: .outer, daysSince: 45, now: now)
        let result = NudgeEngine(settings: settings(cap: 1)).nudges(for: [outer, inner], now: now, calendar: losAngeles)
        #expect(result.map(\.contact) == [inner.id])
    }

    @Test("The weekly check-in appears only on its weekday and counts against the cap")
    func checkIn() throws {
        let wednesday = date(2026, 6, 10)
        let s = try NudgeSettings(dailyCap: 1, quietHours: .none, checkInWeekday: 4)
        let engine = NudgeEngine(settings: s)
        #expect(engine.nudges(for: [], now: wednesday, calendar: losAngeles).map(\.kind) == [.checkIn])
        #expect(engine.nudges(for: [], now: date(2026, 6, 11), calendar: losAngeles).isEmpty)
        let drift = overdueContact("a", daysSince: 25, now: wednesday)
        #expect(engine.nudges(for: [drift], now: wednesday, calendar: losAngeles).map(\.contact) == [drift.id])
    }

    @Test("Days are counted between local midnights, so a contact at 23:59 yesterday is 1 day ago")
    func calendarDays() {
        let c = Contact(id: ContactID("a"), ring: .inner, addedAt: date(2020, 1, 1), lastContact: date(2026, 6, 9, 23, 59))
        #expect(NudgeEngine.daysSinceContact(c, now: date(2026, 6, 10, 0, 1), calendar: losAngeles) == 1)
    }
}
