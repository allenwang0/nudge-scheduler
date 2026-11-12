import Foundation

/// An opaque, stable identifier for a contact. The host app owns the mapping to real people.
public struct ContactID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: ContactID, rhs: ContactID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// How close a contact is. Closer rings get shorter default cadences and win ties.
public enum Ring: Int, CaseIterable, Comparable, Sendable, Codable {
    case inner = 0
    case close = 1
    case outer = 2
    case distant = 3

    /// Days without contact before a drift nudge. `nil` means the ring never gets drift nudges.
    public var defaultCadenceDays: Int? {
        switch self {
        case .inner: 10
        case .close: 20
        case .outer: 40
        case .distant: nil
        }
    }

    public var name: String {
        switch self {
        case .inner: "inner"
        case .close: "close"
        case .outer: "outer"
        case .distant: "distant"
        }
    }

    public static func < (lhs: Ring, rhs: Ring) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A birthday without a year. Feb 29 is allowed.
public struct MonthDay: Hashable, Sendable, Codable {
    public let month: Int
    public let day: Int

    private static let daysInMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    /// Returns nil for dates that never occur, such as Apr 31.
    public init?(month: Int, day: Int) {
        guard (1...12).contains(month), (1...Self.daysInMonth[month - 1]).contains(day) else {
            return nil
        }
        self.month = month
        self.day = day
    }
}

public struct Contact: Sendable {
    public let id: ContactID
    public var ring: Ring
    public var addedAt: Date
    public var lastContact: Date?
    public var birthday: MonthDay?
    /// Overrides the ring's default cadence when set.
    public var cadenceDays: Int?
    public var paused: Bool

    public init(
        id: ContactID,
        ring: Ring,
        addedAt: Date,
        lastContact: Date? = nil,
        birthday: MonthDay? = nil,
        cadenceDays: Int? = nil,
        paused: Bool = false
    ) {
        self.id = id
        self.ring = ring
        self.addedAt = addedAt
        self.lastContact = lastContact
        self.birthday = birthday
        self.cadenceDays = cadenceDays
        self.paused = paused
    }

    /// The cadence in days, or nil if this contact never gets drift nudges.
    public var effectiveCadenceDays: Int? {
        if let cadenceDays, cadenceDays > 0 { return cadenceDays }
        return ring.defaultCadenceDays
    }
}

public enum NudgeKind: Hashable, Sendable {
    case birthday(daysUntil: Int)
    case drift(daysOverdue: Int)
    case checkIn

    /// Tiebreak order when priorities are equal: birthdays, then drift, then the check-in.
    var rank: Int {
        switch self {
        case .birthday: 0
        case .drift: 1
        case .checkIn: 2
        }
    }
}

public struct Nudge: Hashable, Sendable {
    public let kind: NudgeKind
    /// nil only for the weekly check-in, which is not about one contact.
    public let contact: ContactID?
    public let ring: Ring?
    public let priority: Int
}
