import Foundation

/// Snoozes keyed by contact ID, each with an expiry. Expired entries have no effect.
public struct SnoozeBook: Equatable, Sendable, Codable {
    public private(set) var expiries: [ContactID: Date] = [:]

    public static let defaultDays = 7

    public init() {}

    public mutating func snooze(_ id: ContactID, until expiry: Date) {
        expiries[id] = expiry
    }

    public mutating func snooze(
        _ id: ContactID, now: Date, days: Int = defaultDays, calendar: Calendar
    ) {
        snooze(id, until: calendar.date(byAdding: .day, value: days, to: now)!)
    }

    public mutating func clear(_ id: ContactID) {
        expiries[id] = nil
    }

    public func isSnoozed(_ id: ContactID, at now: Date) -> Bool {
        guard let expiry = expiries[id] else { return false }
        return now < expiry
    }

    /// Drops expired entries so storage does not grow without bound.
    public mutating func prune(now: Date) {
        expiries = expiries.filter { now < $0.value }
    }
}
