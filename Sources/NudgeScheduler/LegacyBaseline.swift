import Foundation

/// A re-implementation of the behavior this package replaces, kept only so the simulator can
/// report before-and-after numbers. Do not use it to schedule anything.
enum LegacyBaseline {
    static let fixedCap = 3

    /// Drift bonus capped at 30 (peak 80), no per-contact dedupe, sorted by priority only.
    static func nudges(for contacts: [Contact], now: Date, calendar: Calendar, snoozed: Set<ContactID>) -> [Nudge] {
        var out: [Nudge] = []
        for contact in contacts where !contact.paused && !snoozed.contains(contact.id) {
            for candidate in NudgeEngine.candidates(for: contact, now: now, calendar: calendar) {
                if case .drift(let overdue) = candidate.kind {
                    out.append(
                        Nudge(kind: candidate.kind, contact: contact.id, ring: contact.ring, priority: 50 + min(overdue, 30)))
                } else {
                    out.append(candidate)
                }
            }
        }
        return Array(out.enumerated().sorted { ($1.element.priority, $0.offset) < ($0.element.priority, $1.offset) }
            .map(\.element).prefix(fixedCap))
    }

    /// Spreads deliveries from the end of quiet hours to the start of quiet hours on the same
    /// calendar day, which assumes quiet hours wrap midnight.
    static func dates(count: Int, now: Date, quietHours: QuietHours, calendar: Calendar) -> [Date] {
        guard count > 0 else { return [] }
        let startHour = quietHours.startMinute / 60
        let endHour = quietHours.endMinute / 60
        let today = calendar.startOfDay(for: now)
        let windowStart = calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: today)!
        let windowEnd = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: today)!
        var effectiveStart = max(windowStart, now)
        if effectiveStart >= windowEnd {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            effectiveStart = calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: tomorrow)!
        }
        if count == 1 { return [effectiveStart.addingTimeInterval(300)] }
        let remainingEnd =
            effectiveStart < windowEnd
            ? windowEnd
            : calendar.date(byAdding: .hour, value: startHour - endHour, to: effectiveStart)!
        let interval = remainingEnd.timeIntervalSince(effectiveStart) / Double(count)
        return (0..<count).map { effectiveStart.addingTimeInterval(interval * Double($0) + 300) }
    }
}
