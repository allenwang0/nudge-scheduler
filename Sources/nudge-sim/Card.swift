import Foundation
import NudgeScheduler

/// site/card.json, schema_version 1.
struct Card: Encodable {
    struct Metric: Encodable {
        let label: String
        let value: Double
        let unit: String
        let higher_is_better: Bool
    }
    struct Series: Encodable {
        let name: String
        let style: String
        let points: [[Double]]
    }
    struct Chart: Encodable {
        let type = "line"
        let x_label: String
        let x_unit: String
        let x_scale = "linear"
        let y_label: String
        let y_unit: String
        let y_scale = "linear"
        let series: [Series]
    }

    let schema_version = 1
    let repo = "nudge-scheduler"
    let sha: String
    let generated_at: String
    let command: String
    let data_note: String
    let metric: Metric
    let takeaway: String
    let chart: Chart

    static func make(_ r: Results, sha: String, command: String) -> Card {
        let point = r.pooledSweep[r.defaultCap - 1]
        let slow = r.slowestPooledRing(point)
        let p90 = point.stats(slow).p90Wait
        let styles = ["solid", "dashed", "dots"]
        let series = Results.driftRings.enumerated().map { i, ring in
            Series(
                name: "\(ring.name) ring", style: styles[i],
                points: r.pooledSweep.map { [Double($0.cap), Double($0.stats(ring).p90Wait)] })
        }
        let atOne = r.pooledSweep[0].stats(slow).p90Wait
        let takeaway =
            "At cap \(r.defaultCap), 90% of \(slow.name)-ring contacts get a nudge within \(days(p90)) of falling overdue; at cap 1, \(days(atOne))."
        precondition(takeaway.count <= 140, "card takeaway over 140 characters: \(takeaway)")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return Card(
            sha: sha,
            generated_at: formatter.string(from: Date()),
            command: command,
            data_note:
                "Synthetic: 40 invented contacts per run, seeds \(r.seed)-\(r.seed + UInt64(r.sweepSeeds) - 1), 365 simulated days each, reply probability \(r.main.replyProbability)",
            metric: Metric(
                label: "p90 wait from overdue to nudge, slowest ring, cap \(r.defaultCap)", value: Double(p90), unit: "days",
                higher_is_better: false),
            takeaway: takeaway,
            chart: Chart(
                x_label: "Daily cap", x_unit: "nudges per day", y_label: "p90 wait from overdue to nudge", y_unit: "days", series: series))
    }
}
