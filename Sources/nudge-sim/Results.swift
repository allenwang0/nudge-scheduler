import NudgeScheduler

/// Wait statistics for one cap, pooled over many seeds.
struct SweepPoint: Encodable {
    struct RingStats: Encodable {
        let ring: Ring
        let episodes: Int
        let p90Wait: Int
        let maxWait: Int
        let neverNudged: Int
    }

    let cap: Int
    let rings: [RingStats]
    let meanNudgesPerDay: Double

    init(cap: Int, runs: [SimulationResult]) {
        self.cap = cap
        rings = Results.driftRings.map { ring in
            let waits = runs.flatMap(\.waits).filter { $0.ring == ring }
            let days = waits.map(\.days).sorted()
            let p90 = days.isEmpty ? 0 : days[Int((0.9 * Double(days.count)).rounded(.up)) - 1]
            let resolved = runs.compactMap { $0.summary(for: ring)?.resolvedWithoutNudge }.reduce(0, +)
            return RingStats(
                ring: ring, episodes: waits.count + resolved, p90Wait: p90, maxWait: days.last ?? 0,
                neverNudged: waits.filter(\.censored).count)
        }
        meanNudgesPerDay = (runs.map(\.meanNudgesPerDay).reduce(0, +) / Double(runs.count) * 1000).rounded() / 1000
    }

    func stats(_ ring: Ring) -> RingStats { rings.first { $0.ring == ring }! }
}

struct Results: Encodable {
    let seed: UInt64
    let defaultCap: Int
    let sweepSeeds: Int
    /// Current engine, quiet 22:00 to 08:00, seeds seed..<seed+sweepSeeds per cap.
    let pooledSweep: [SweepPoint]
    /// Current engine, quiet 22:00 to 08:00, one run per cap 1...10 at `seed`.
    let sweep: [SimulationResult]
    /// Legacy behavior at its fixed cap of 3, quiet 22:00 to 08:00.
    let legacy: SimulationResult
    /// Quiet 01:00 to 07:00, cap 3.
    let nightShift: SimulationResult
    let nightShiftLegacy: SimulationResult

    var main: SimulationResult { sweep[defaultCap - 1] }

    static let driftRings: [Ring] = [.inner, .close, .outer]

    func maxWait(_ r: SimulationResult, _ ring: Ring) -> Int {
        r.summary(for: ring)?.maxWaitIncludingOpen ?? 0
    }

    /// The drift ring with the longest worst-case wait in a run.
    func slowestRing(_ r: SimulationResult) -> Ring {
        Self.driftRings.max { (maxWait(r, $0), -$0.rawValue) < (maxWait(r, $1), -$1.rawValue) }!
    }

    /// The drift ring with the highest pooled p90 wait at a cap; ties go to the longer max wait.
    func slowestPooledRing(_ p: SweepPoint) -> Ring {
        func key(_ r: Ring) -> (Int, Int, Int, Int) {
            let s = p.stats(r)
            return (s.p90Wait, s.maxWait, s.neverNudged, -r.rawValue)
        }
        return Self.driftRings.max { key($0) < key($1) }!
    }
}

func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }
