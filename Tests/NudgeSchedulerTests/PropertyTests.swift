import Foundation
import Testing
@testable import NudgeScheduler

/// Generated-input tests. A seeded generator picks the cases, so a failure reproduces exactly.
struct PropertyTests {
    /// 3 days around each 2026 US DST change in America/Los_Angeles, on a 15-minute grid.
    static let dstInstants: [Date] = [date(2026, 3, 7, 0, 0), date(2026, 10, 31, 0, 0)].flatMap { start in
        (0..<(3 * 96)).map { start.addingTimeInterval(TimeInterval($0 * 15 * 60)) }
    }

    @Test(
        "Deliveries never fall in quiet hours, never precede now, and strictly increase",
        arguments: 0..<24)
    func deliveryInvariants(startHour: Int) throws {
        var rng = SeededGenerator(seed: UInt64(startHour))
        for endHour in 0..<24 {
            let quiet = try QuietHours(startHour: startHour, endHour: endHour)
            for count in 1...10 {
                for _ in 0..<12 {
                    let now = Self.dstInstants[rng.below(Self.dstInstants.count)]
                    let dates = DeliveryPlanner.dates(count: count, now: now, quietHours: quiet, calendar: losAngeles)
                    try #require(dates.count == count)
                    for (i, d) in dates.enumerated() {
                        try #require(d > now)
                        try #require(!quiet.contains(d, calendar: losAngeles), "quiet \(startHour)-\(endHour) now \(now) got \(d)")
                        if i > 0 { try #require(d > dates[i - 1]) }
                    }
                }
            }
        }
    }

    @Test("Every 15-minute instant across both DST days, for the default and a non-wrapping window")
    func dstGrid() throws {
        for quiet in [
            try QuietHours(startHour: 22, endHour: 8), try QuietHours(startHour: 1, endHour: 7), try QuietHours(startHour: 2, endHour: 3),
        ] {
            for now in Self.dstInstants {
                let dates = DeliveryPlanner.dates(count: 10, now: now, quietHours: quiet, calendar: losAngeles)
                try #require(dates.count == 10)
                try #require(dates.allSatisfy { $0 > now && !quiet.contains($0, calendar: losAngeles) })
                try #require(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 })
            }
        }
    }

    @Test("Generated contact sets never exceed the cap and never repeat a contact", arguments: 1...10)
    func capAndUniqueness(cap: Int) {
        var rng = SeededGenerator(seed: 1000 + UInt64(cap))
        let engine = NudgeEngine(settings: settings(cap: cap))
        for _ in 0..<200 {
            let now = date(2026, 1, 1).addingTimeInterval(TimeInterval(rng.below(365 * 86400)))
            let contacts = (0..<rng.below(30)).map { i in
                Contact(
                    id: ContactID("g\(i)"), ring: Ring.allCases[rng.below(4)], addedAt: date(2020, 1, 1),
                    lastContact: now.addingTimeInterval(-TimeInterval(rng.below(120 * 86400))),
                    birthday: MonthDay(month: 1 + rng.below(12), day: 1 + rng.below(28)))
            }
            let result = engine.nudges(for: contacts, now: now, calendar: losAngeles)
            #expect(result.count <= cap)
            let ids = result.compactMap(\.contact)
            #expect(Set(ids).count == ids.count)
            #expect(zip(result, result.dropFirst()).allSatisfy { $0.priority >= $1.priority })
        }
    }

    @Test("Output order does not depend on input order (100 seeded shuffles)")
    func orderIndependence() {
        let now = date(2026, 6, 10)
        let contacts = (0..<12).map { overdueContact("c\($0 % 6)\($0)", ring: Ring.allCases[$0 % 3], daysSince: 45, now: now) }
        let engine = NudgeEngine(settings: settings(cap: 10))
        let expected = engine.nudges(for: contacts, now: now, calendar: losAngeles)
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<100 {
            #expect(engine.nudges(for: contacts.shuffled(using: &rng), now: now, calendar: losAngeles) == expected)
        }
    }
}
