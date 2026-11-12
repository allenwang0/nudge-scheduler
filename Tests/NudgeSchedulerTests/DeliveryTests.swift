import Foundation
import Testing
@testable import NudgeScheduler

struct DeliveryTests {
    func check(_ dates: [Date], count: Int, now: Date, quiet: QuietHours, calendar: Calendar = losAngeles) {
        #expect(dates.count == count)
        for (i, d) in dates.enumerated() {
            #expect(d > now)
            #expect(!quiet.contains(d, calendar: calendar), "\(d) inside \(quiet)")
            if i > 0 { #expect(d > dates[i - 1]) }
        }
    }

    @Test("Source bug: quiet 01:00 to 07:00 with 3 nudges at 23:00 delivered at 07:05, 05:05, 03:05")
    func nonWrappingQuietHours() throws {
        let quiet = try QuietHours(startHour: 1, endHour: 7)
        let now = date(2026, 6, 10, 23, 0)
        let dates = DeliveryPlanner.dates(count: 3, now: now, quietHours: quiet, calendar: losAngeles)
        check(dates, count: 3, now: now, quiet: quiet)
        let legacy = LegacyBaseline.dates(count: 3, now: now, quietHours: quiet, calendar: losAngeles)
        #expect(legacy.filter { quiet.contains($0, calendar: losAngeles) }.count == 2)
    }

    @Test("Same-day delivery works with non-wrapping quiet hours")
    func sameDay() throws {
        let quiet = try QuietHours(startHour: 1, endHour: 7)
        let now = date(2026, 6, 10, 9, 0)
        let dates = DeliveryPlanner.dates(count: 3, now: now, quietHours: quiet, calendar: losAngeles)
        #expect(dates.allSatisfy { losAngeles.isDate($0, inSameDayAs: now) })
    }

    @Test("Equal start and end means no quiet hours, and deliveries are not stacked on one minute")
    func equalStartEnd() throws {
        let quiet = try QuietHours(startHour: 9, endHour: 9)
        #expect(quiet.isEmpty)
        let now = date(2026, 6, 10, 3, 0)
        let dates = DeliveryPlanner.dates(count: 4, now: now, quietHours: quiet, calendar: losAngeles)
        check(dates, count: 4, now: now, quiet: quiet)
        #expect(Set(dates).count == 4)
    }

    @Test("Quiet hours leaving less than an hour a day are rejected")
    func tooLong() {
        #expect(throws: QuietHours.Error.allowedWindowTooShort(minutes: 30)) {
            try QuietHours(startMinute: 8 * 60, endMinute: 7 * 60 + 30)
        }
    }

    @Test("Inside quiet hours, delivery waits for the window to open")
    func waitsForMorning() throws {
        let quiet = try QuietHours(startHour: 22, endHour: 8)
        let now = date(2026, 6, 10, 2, 0)
        let first = DeliveryPlanner.dates(count: 1, now: now, quietHours: quiet, calendar: losAngeles)[0]
        #expect(first == date(2026, 6, 10, 8, 0))
    }
}
