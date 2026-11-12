import Foundation
@testable import NudgeScheduler

let losAngeles: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
}()

func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, calendar: Calendar = losAngeles) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

func settings(cap: Int = 3, quiet: QuietHours = try! QuietHours(startHour: 22, endHour: 8)) -> NudgeSettings {
    try! NudgeSettings(dailyCap: cap, quietHours: quiet)
}

func overdueContact(_ id: String, ring: Ring = .close, daysSince: Int, now: Date) -> Contact {
    Contact(
        id: ContactID(id), ring: ring, addedAt: date(2020, 1, 1),
        lastContact: losAngeles.date(byAdding: .day, value: -daysSince, to: now)!)
}
