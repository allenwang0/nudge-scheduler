import Foundation

/// A seeded replay of synthetic contacts over many days. Every input is generated from the seed.
public struct SimulationConfig: Sendable {
    public enum Policy: String, Codable, Sendable {
        case current
        case legacy
    }

    public var seed: UInt64 = 42
    public var days = 365
    public var dailyCap = 3
    public var quietHours: QuietHours
    public var policy: Policy = .current
    /// Probability the simulated user reaches out after a nudge. An assumption, not a measurement.
    public var replyProbability = 0.6
    /// Probability the user snoozes a nudge they did not act on.
    public var snoozeProbability = 0.25

    public static let ringSizes: [(Ring, Int)] = [(.inner, 5), (.close, 10), (.outer, 15), (.distant, 10)]
    /// Daily chance of contact that happens without a nudge.
    public static let organicRate: [Ring: Double] = [.inner: 0.06, .close: 0.03, .outer: 0.012, .distant: 0.005]
    public static let timeZone = TimeZone(identifier: "America/Los_Angeles")!
    /// 2026-01-01 00:00 in America/Los_Angeles. The year covers both 2026 DST changes.
    public static let startDate = Date(timeIntervalSince1970: 1_767_254_400)

    public init(quietHours: QuietHours) {
        self.quietHours = quietHours
    }

    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }
}

public struct SimulationResult: Codable, Equatable, Sendable {
    public struct ContactRow: Codable, Equatable, Sendable {
        public let id: String
        public let ring: Ring
    }

    public struct Delivery: Codable, Equatable, Sendable {
        public let day: Int
        /// Index into `contacts`, or -1 for the weekly check-in.
        public let contact: Int
        public let kind: String
        public let minuteOfDay: Int
        public let insideQuietHours: Bool
    }

    public struct Wait: Codable, Equatable, Sendable {
        public let contact: Int
        public let ring: Ring
        public let startDay: Int
        public let days: Int
        /// True when the year ended before any nudge; `days` is then a lower bound.
        public let censored: Bool
    }

    public struct RingSummary: Codable, Equatable, Sendable {
        public let ring: Ring
        public let episodes: Int
        public let nudged: Int
        public let resolvedWithoutNudge: Int
        public let censored: Int
        public let medianWait: Int?
        public let p90Wait: Int?
        public let maxWait: Int?
        /// Longest wait counting censored episodes at their lower bound.
        public let maxWaitIncludingOpen: Int?
    }

    public let seed: UInt64
    public let days: Int
    public let dailyCap: Int
    public let quietStartMinute: Int
    public let quietEndMinute: Int
    public let policy: SimulationConfig.Policy
    public let replyProbability: Double
    public let contacts: [ContactRow]
    /// Per contact, per day: 0 if not overdue, else days past cadence plus 1.
    public let overdue: [[Int]]
    public let deliveries: [Delivery]
    public let waits: [Wait]
    public let rings: [RingSummary]
    public let quietHourViolations: Int
    /// Slots taken by a second nudge for a contact already nudged that day.
    public let duplicateSlots: Int
    public let meanNudgesPerDay: Double

    public func summary(for ring: Ring) -> RingSummary? {
        rings.first { $0.ring == ring }
    }
}

public enum Simulation {
    public static func makeContacts(rng: inout SeededGenerator, calendar: Calendar) -> [Contact] {
        var contacts: [Contact] = []
        let start = SimulationConfig.startDate
        let added = calendar.date(byAdding: .day, value: -365, to: start)!
        for (ring, size) in SimulationConfig.ringSizes {
            for _ in 0..<size {
                let id = ContactID(String(format: "c%02d", contacts.count + 1))
                let gapLimit = (ring.defaultCadenceDays ?? 60) * 3 / 2
                let last = calendar.date(byAdding: .day, value: -rng.below(gapLimit), to: start)!
                var birthday: MonthDay?
                while birthday == nil {
                    birthday = MonthDay(month: 1 + rng.below(12), day: 1 + rng.below(31))
                }
                contacts.append(Contact(id: id, ring: ring, addedAt: added, lastContact: last, birthday: birthday))
            }
        }
        contacts[3].birthday = MonthDay(month: 2, day: 29)
        return contacts
    }

    public static func run(_ config: SimulationConfig) -> SimulationResult {
        let calendar = SimulationConfig.calendar
        var rng = SeededGenerator(seed: config.seed)
        var contacts = makeContacts(rng: &rng, calendar: calendar)
        let engine = NudgeEngine(settings: try! NudgeSettings(dailyCap: config.dailyCap, quietHours: config.quietHours))
        var snoozes = SnoozeBook()
        var legacySnoozed = Set<ContactID>()

        var overdue = Array(repeating: [Int](), count: contacts.count)
        var deliveries: [SimulationResult.Delivery] = []
        var waits: [SimulationResult.Wait] = []
        var episodeStart: [Int?] = Array(repeating: nil, count: contacts.count)
        var episodeNudged = Array(repeating: false, count: contacts.count)
        var resolvedWithoutNudge: [Ring: Int] = [:]
        var duplicateSlots = 0
        var nudgeCount = 0

        func touched(_ i: Int, at date: Date) {
            contacts[i].lastContact = date
            if episodeStart[i] != nil && !episodeNudged[i] {
                resolvedWithoutNudge[contacts[i].ring, default: 0] += 1
            }
            episodeStart[i] = nil
            episodeNudged[i] = false
        }

        for day in 0..<config.days {
            let dayStart = calendar.date(byAdding: .day, value: day, to: SimulationConfig.startDate)!
            for i in contacts.indices where rng.chance(SimulationConfig.organicRate[contacts[i].ring]!) {
                touched(i, at: calendar.date(bySettingHour: 12, minute: 0, second: 0, of: dayStart)!)
            }
            let openMinute = rng.below(1440)
            let now = calendar.date(byAdding: .minute, value: openMinute, to: dayStart)!

            for i in contacts.indices {
                let level = NudgeEngine.daysOverdue(contacts[i], now: now, calendar: calendar).map { max(0, $0 + 1) } ?? 0
                overdue[i].append(level)
                if level > 0 && episodeStart[i] == nil { episodeStart[i] = day }
            }

            let nudges: [Nudge]
            let times: [Date]
            switch config.policy {
            case .current:
                snoozes.prune(now: now)
                nudges = engine.nudges(for: contacts, now: now, calendar: calendar, snoozes: snoozes)
                times = DeliveryPlanner.dates(count: nudges.count, now: now, quietHours: config.quietHours, calendar: calendar)
            case .legacy:
                nudges = LegacyBaseline.nudges(for: contacts, now: now, calendar: calendar, snoozed: legacySnoozed)
                times = LegacyBaseline.dates(count: nudges.count, now: now, quietHours: config.quietHours, calendar: calendar)
            }
            nudgeCount += nudges.count

            var seenToday = Set<ContactID>()
            for (nudge, time) in zip(nudges, times) {
                let c = calendar.dateComponents([.hour, .minute], from: time)
                let index = nudge.contact.flatMap { id in contacts.firstIndex { $0.id == id } } ?? -1
                deliveries.append(
                    .init(
                        day: day, contact: index, kind: kindName(nudge.kind), minuteOfDay: c.hour! * 60 + c.minute!,
                        insideQuietHours: config.quietHours.contains(time, calendar: calendar)))
                guard index >= 0 else { continue }
                if !seenToday.insert(nudge.contact!).inserted {
                    duplicateSlots += 1
                    continue
                }
                if let start = episodeStart[index], !episodeNudged[index] {
                    episodeNudged[index] = true
                    waits.append(.init(contact: index, ring: contacts[index].ring, startDay: start, days: day - start, censored: false))
                }
                if rng.chance(config.replyProbability) {
                    touched(index, at: time)
                } else if rng.chance(config.snoozeProbability) {
                    switch config.policy {
                    case .current: snoozes.snooze(nudge.contact!, now: time, calendar: calendar)
                    case .legacy: legacySnoozed.insert(nudge.contact!)
                    }
                }
            }
        }

        for i in contacts.indices {
            if let start = episodeStart[i], !episodeNudged[i] {
                waits.append(.init(contact: i, ring: contacts[i].ring, startDay: start, days: config.days - start, censored: true))
            }
        }

        let rings = Ring.allCases.filter { $0.defaultCadenceDays != nil }.map { ring in
            summarize(ring: ring, waits: waits.filter { $0.ring == ring }, resolved: resolvedWithoutNudge[ring] ?? 0)
        }
        return SimulationResult(
            seed: config.seed, days: config.days, dailyCap: config.dailyCap,
            quietStartMinute: config.quietHours.startMinute, quietEndMinute: config.quietHours.endMinute,
            policy: config.policy, replyProbability: config.replyProbability,
            contacts: contacts.map { .init(id: $0.id.rawValue, ring: $0.ring) },
            overdue: overdue, deliveries: deliveries, waits: waits, rings: rings,
            quietHourViolations: deliveries.filter(\.insideQuietHours).count,
            duplicateSlots: duplicateSlots,
            meanNudgesPerDay: (Double(nudgeCount) / Double(config.days) * 1000).rounded() / 1000)
    }

    static func kindName(_ kind: NudgeKind) -> String {
        switch kind {
        case .birthday: "birthday"
        case .drift: "drift"
        case .checkIn: "check-in"
        }
    }

    static func summarize(ring: Ring, waits: [SimulationResult.Wait], resolved: Int) -> SimulationResult.RingSummary {
        let closed = waits.filter { !$0.censored }.map(\.days).sorted()
        func rank(_ q: Double) -> Int? {
            closed.isEmpty ? nil : closed[min(closed.count - 1, Int((q * Double(closed.count)).rounded(.up)) - 1)]
        }
        return .init(
            ring: ring, episodes: waits.count + resolved, nudged: closed.count, resolvedWithoutNudge: resolved,
            censored: waits.count - closed.count, medianWait: rank(0.5), p90Wait: rank(0.9), maxWait: closed.last,
            maxWaitIncludingOpen: waits.map(\.days).max())
    }

    /// Stable JSON for a result: sorted keys, so the same seed gives the same bytes.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
