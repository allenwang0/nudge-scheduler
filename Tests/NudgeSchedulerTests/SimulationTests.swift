import Foundation
import Testing
@testable import NudgeScheduler

struct SimulationTests {
    static let defaultQuiet = try! QuietHours(startHour: 22, endHour: 8)
    static let nightShiftQuiet = try! QuietHours(startHour: 1, endHour: 7)

    @Test("The same seed gives byte-identical JSON")
    func deterministic() throws {
        let config = SimulationConfig(quietHours: Self.defaultQuiet)
        #expect(try Simulation.encode(Simulation.run(config)) == Simulation.encode(Simulation.run(config)))
        var other = config
        other.seed = 43
        #expect(try Simulation.encode(Simulation.run(other)) != Simulation.encode(Simulation.run(config)))
    }

    @Test("A full year never delivers in quiet hours or exceeds the cap", arguments: [1, 3, 10])
    func yearInvariants(cap: Int) {
        for quiet in [Self.defaultQuiet, Self.nightShiftQuiet] {
            var config = SimulationConfig(quietHours: quiet)
            config.dailyCap = cap
            let result = Simulation.run(config)
            #expect(result.quietHourViolations == 0)
            #expect(result.duplicateSlots == 0)
            let perDay = Dictionary(grouping: result.deliveries, by: \.day)
            #expect(perDay.values.allSatisfy { $0.count <= cap })
        }
    }

    @Test("The legacy baseline does violate non-wrapping quiet hours, so the comparison measures something")
    func legacyViolates() {
        var config = SimulationConfig(quietHours: Self.nightShiftQuiet)
        config.policy = .legacy
        #expect(Simulation.run(config).quietHourViolations > 0)
    }

    @Test("Synthetic contacts follow the documented ring sizes and include a Feb 29 birthday")
    func contacts() {
        var rng = SeededGenerator(seed: 42)
        let contacts = Simulation.makeContacts(rng: &rng, calendar: SimulationConfig.calendar)
        #expect(contacts.count == 40)
        #expect(contacts.filter { $0.ring == .outer }.count == 15)
        #expect(contacts.contains { $0.birthday == MonthDay(month: 2, day: 29) })
    }
}
