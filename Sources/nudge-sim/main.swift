import Foundation
import NudgeScheduler

struct Options {
    var seed: UInt64 = 42
    var out = "site"
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var it = args.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--seed":
            guard let v = it.next().flatMap(UInt64.init) else { fail("--seed needs an unsigned integer") }
            o.seed = v
        case "--out":
            guard let v = it.next() else { fail("--out needs a directory") }
            o.out = v
        default:
            fail("unknown argument \(a)\nusage: nudge-sim [--seed N] [--out DIR]")
        }
    }
    return o
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("nudge-sim: \(message)\n".utf8))
    exit(1)
}

func gitHead() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["git", "rev-parse", "HEAD"]
    let pipe = Pipe()
    p.standardOutput = pipe
    do { try p.run() } catch { fail("cannot run git: \(error)") }
    p.waitUntilExit()
    let sha = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard p.terminationStatus == 0, sha.count == 40 else { fail("git rev-parse HEAD failed; run from the repo") }
    return sha
}

let options = parse(CommandLine.arguments)
let defaultQuiet = try QuietHours(startHour: 22, endHour: 8)
let nightQuiet = try QuietHours(startHour: 1, endHour: 7)

func run(cap: Int = 3, quiet: QuietHours = defaultQuiet, policy: SimulationConfig.Policy = .current) -> SimulationResult {
    var c = SimulationConfig(quietHours: quiet)
    c.seed = options.seed
    c.dailyCap = cap
    c.policy = policy
    return Simulation.run(c)
}

let sweepSeeds = 20
let pooled = NudgeSettings.capRange.map { cap in
    SweepPoint(
        cap: cap,
        runs: (0..<UInt64(sweepSeeds)).map { s in
            var c = SimulationConfig(quietHours: defaultQuiet)
            c.seed = options.seed &+ s
            c.dailyCap = cap
            return Simulation.run(c)
        })
}

let results = Results(
    seed: options.seed,
    defaultCap: 3,
    sweepSeeds: sweepSeeds,
    pooledSweep: pooled,
    sweep: NudgeSettings.capRange.map { run(cap: $0) },
    legacy: run(policy: .legacy),
    nightShift: run(quiet: nightQuiet),
    nightShiftLegacy: run(quiet: nightQuiet, policy: .legacy))

let outDir = URL(fileURLWithPath: options.out, isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try Simulation.encode(results).write(to: outDir.appendingPathComponent("results.json"))
try Report.html(results).write(to: outDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
let card = Card.make(results, sha: gitHead(), command: "swift run -c release nudge-sim --seed \(options.seed) --out \(options.out)")
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
try encoder.encode(card).write(to: outDir.appendingPathComponent("card.json"))

let main = results.main
print("seed \(options.seed), \(main.days) days, \(main.contacts.count) synthetic contacts, cap \(main.dailyCap)")
for r in main.rings {
    let legacy = results.legacy.summary(for: r.ring)!
    print(
        "  \(r.ring.name): median wait \(r.medianWait.map(String.init) ?? "-") d, max \(r.maxWaitIncludingOpen.map(String.init) ?? "-") d"
            + " (legacy max \(legacy.maxWaitIncludingOpen.map(String.init) ?? "-") d)")
}
print(
    "  quiet-hour violations, quiet 01:00-07:00: \(results.nightShift.quietHourViolations) (legacy \(results.nightShiftLegacy.quietHourViolations))"
)
print("  duplicate slots: \(main.duplicateSlots) (legacy \(results.legacy.duplicateSlots))")
print("  takeaway: \(card.takeaway)")
print("wrote \(options.out)/index.html, results.json, card.json")
