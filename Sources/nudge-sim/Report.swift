import Foundation
import NudgeScheduler

/// Report page built on report-kit v1 (vendored in site/kit/, never edited). Every number is computed
/// here from `Results`; charts are drawn client-side by kit/charts.js and the small local script below
/// from one inline JSON block, so the ten cap views share one copy of the data.
enum Report {
    static let repo = "https://github.com/allenwang0/nudge-scheduler"
    static let hub = "https://allenwang0.github.io/"

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func hhmm(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    static func window(_ run: SimulationResult) -> String {
        "\(hhmm(run.quietStartMinute))–\(hhmm(run.quietEndMinute))"
    }

    static func percent(_ n: Int, _ d: Int) -> String {
        guard d > 0 else { return "n/a" }
        let p = 100 * Double(n) / Double(d)
        return p >= 10 ? "\(Int(p.rounded()))&#8239;%" : String(format: "%.1f&#8239;%%", p)
    }

    // MARK: Embedded data

    struct RingRow: Encodable {
        let ring: String
        let median: Int?
        let p90: Int?
        let max: Int?
        let never: Int
        let episodes: Int
    }

    struct RunData: Encodable {
        let cap: Int
        let quiet: [Int]
        let deliveries: Int
        let violations: Int
        let hours: [Int]
        let inside: [Int]
        let perDay: Double
        let rings: [RingRow]
    }

    struct PooledRow: Encodable {
        let cap: Int
        let p90: [Int]
        let max: [Int]
        let never: [Int]
        let episodes: [Int]
        let perDay: Double
    }

    struct PageData: Encodable {
        let seed: UInt64
        let defaultCap: Int
        let sweepSeeds: Int
        let rings: [String]
        let caps: [RunData]
        let legacy: RunData
        let night: RunData
        let nightLegacy: RunData
        let pooled: [PooledRow]
    }

    static func runData(_ run: SimulationResult) -> RunData {
        var hours = Array(repeating: 0, count: 24)
        var inside = Array(repeating: 0, count: 24)
        for d in run.deliveries {
            hours[d.minuteOfDay / 60] += 1
            if d.insideQuietHours { inside[d.minuteOfDay / 60] += 1 }
        }
        let rings = Results.driftRings.map { ring in
            let s = run.summary(for: ring)
            return RingRow(
                ring: ring.name, median: s?.medianWait, p90: s?.p90Wait, max: s?.maxWaitIncludingOpen, never: s?.censored ?? 0,
                episodes: s?.episodes ?? 0)
        }
        return RunData(
            cap: run.dailyCap, quiet: [run.quietStartMinute, run.quietEndMinute], deliveries: run.deliveries.count,
            violations: run.quietHourViolations, hours: hours, inside: inside, perDay: run.meanNudgesPerDay, rings: rings)
    }

    static func pageData(_ r: Results) -> PageData {
        PageData(
            seed: r.seed, defaultCap: r.defaultCap, sweepSeeds: r.sweepSeeds, rings: Results.driftRings.map(\.name),
            caps: r.sweep.map(runData), legacy: runData(r.legacy), night: runData(r.nightShift), nightLegacy: runData(r.nightShiftLegacy),
            pooled: r.pooledSweep.map { p in
                let s = Results.driftRings.map { p.stats($0) }
                return PooledRow(
                    cap: p.cap, p90: s.map(\.p90Wait), max: s.map(\.maxWait), never: s.map(\.neverNudged), episodes: s.map(\.episodes),
                    perDay: p.meanNudgesPerDay)
            })
    }

    static func json(_ r: Results) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let s = String(decoding: try! encoder.encode(pageData(r)), as: UTF8.self)
        return s.replacingOccurrences(of: "</", with: "<\\/")
    }

    // MARK: Page

    static func html(_ r: Results, sha: String) -> String {
        let main = r.main
        let legacy = r.legacy
        let night = r.nightShift
        let nightOld = r.nightShiftLegacy
        let rings = Results.driftRings
        func maxWait(_ run: SimulationResult) -> Int { rings.map { r.maxWait(run, $0) }.max() ?? 0 }
        func never(_ run: SimulationResult) -> Int { rings.compactMap { run.summary(for: $0)?.censored }.reduce(0, +) }
        let newMax = maxWait(main)
        let oldMax = maxWait(legacy)
        let waits = rings.map { "\(r.maxWait(main, $0))" }.joined(separator: " / ")
        let oldWaits = rings.map { "\(r.maxWait(legacy, $0))" }.joined(separator: " / ")
        let neverNew = never(main)
        let neverOld = never(legacy)

        let point = r.pooledSweep[r.defaultCap - 1]
        let slow = r.slowestPooledRing(point)
        let p90Default = point.stats(slow).p90Wait
        let p90One = r.pooledSweep[0].stats(slow).p90Wait
        let aboveDefault = r.pooledSweep.filter { $0.cap >= r.defaultCap }
        let worstAbove = aboveDefault.flatMap { p in rings.map { p.stats($0).p90Wait } }.max() ?? 0
        let lastCap = r.pooledSweep.last!
        let perDayDefault = String(format: "%.2f", point.meanNudgesPerDay)
        let perDayLast = String(format: "%.2f", lastCap.meanNudgesPerDay)
        let perDayOne = String(format: "%.2f", r.pooledSweep[0].meanNudgesPerDay)
        let seeds = "\(r.seed)–\(r.seed + UInt64(r.sweepSeeds) - 1)"

        let h1 =
            newMax < oldMax
            ? "The new engine nudged every overdue friend within \(days(newMax)); the old rules took up to \(oldMax)"
            : "The new engine's longest wait was \(days(newMax)), against \(days(oldMax)) under the old rules"
        let quietH2 =
            nightOld.quietHourViolations > night.quietHourViolations
            ? "With quiet hours that don't cross midnight, the old planner delivered \(nightOld.quietHourViolations) of \(nightOld.deliveries.count) nudges inside them"
            : "Neither planner delivered inside a quiet window that doesn't cross midnight"
        let capH2 =
            "At cap \(r.defaultCap), 90&#8239;% of waits end within \(days(p90Default)); raising the cap adds few nudges"
        let exploreH2 =
            r.sweep.allSatisfy { $0.quietHourViolations == 0 }
            ? "At every cap from \(r.sweep.first!.dailyCap) to \(r.sweep.last!.dailyCap), the engine delivers nothing inside quiet hours"
            : "Waits and delivery times at each cap, seed \(r.seed)"
        let compareH2 =
            "Against the old rules, the longest wait in each ring drops from \(oldWaits) days to \(waits)"

        let neverCard: String
        if neverOld > neverNew {
            neverCard = card(
                "Never nudged by year end", "\(neverNew)", "episodes", "vs \(neverOld) under the old rules",
                "Overdue episodes still open on day \(main.days) · seed \(r.seed)", "#compare")
        } else {
            neverCard = card(
                "Never nudged by year end", "\(neverNew)", "episodes", "\(neverOld) under the old rules",
                "Overdue episodes still open on day \(main.days) · seed \(r.seed)", "#compare")
        }
        let cards = [
            card(
                "Inside quiet hours, \(window(night))", "\(night.quietHourViolations)", "of \(night.deliveries.count)",
                "vs \(nightOld.quietHourViolations) of \(nightOld.deliveries.count) (\(percent(nightOld.quietHourViolations, nightOld.deliveries.count))) for the old rules",
                "A window that doesn't cross midnight · seed \(r.seed)", "#quiet"),
            card(
                "Inside quiet hours, \(window(main))", "\(main.quietHourViolations)", "of \(main.deliveries.count)",
                "vs \(legacy.quietHourViolations) of \(legacy.deliveries.count) for the old rules",
                "The default window · seed \(r.seed)", "#quiet"),
            neverCard,
        ].joined()

        let shows = [
            "On one synthetic year (seed \(r.seed), cap \(r.defaultCap)), the engine's longest wait is \(days(newMax)) against \(days(oldMax)) for the re-implemented old rules.",
            r.sweep.allSatisfy { $0.quietHourViolations == 0 } && night.quietHourViolations == 0
                ? "At seed \(r.seed), the engine never delivered inside quiet hours at any cap, nor with a window that doesn't cross midnight."
                : "At seed \(r.seed), the engine delivered \(night.quietHourViolations) of \(night.deliveries.count) nudges inside a window that doesn't cross midnight.",
            "Pooled over \(r.sweepSeeds) seeds, cap \(r.defaultCap) keeps the \(slow.name) ring's p90 wait at \(days(p90Default)), against \(days(p90One)) at cap 1.",
        ]
        let notShows = [
            "Real friend groups: contacts, reply and snooze rates are invented.",
            "How the shipped old app behaved: its rules were re-implemented from a description.",
            "Seed-to-seed spread of the before/after table, which comes from one seed.",
            "Spread across the \(r.sweepSeeds) sweep seeds: waits are pooled before taking p90.",
        ]
        let env: [(String, String)] = [
            ("Seed (comparison, cap views)", "\(r.seed)"),
            ("Seeds (cap sweep)", seeds),
            ("Simulated span", "\(main.days) days of 2026, America/Los_Angeles"),
            (
                "Contacts",
                "\(main.contacts.count) invented (\(SimulationConfig.ringSizes.map { "\($0.1) \($0.0.name)" }.joined(separator: ", ")))"
            ),
            ("Reply probability", "\(main.replyProbability)"),
            ("Default quiet hours", window(main)),
            ("Stress quiet hours", window(night)),
            (
                "Old rules",
                "hard cap \(legacy.dailyCap), drift priority capped at 80, no per-contact dedupe, snoozes never expire, same-day window arithmetic"
            ),
            ("Generated from commit", String(sha.prefix(12))),
            ("Data", "site/results.json"),
        ]
        let envRows = env.map { "<tr><th scope=\"row\">\(esc($0.0))</th><td>\(esc($0.1))</td></tr>" }.joined()
        let capOptions = r.sweep.map {
            "<option value=\"\($0.dailyCap)\"\($0.dailyCap == r.defaultCap ? " selected" : "")>Cap \($0.dailyCap)\($0.dailyCap == r.defaultCap ? " (default)" : "")</option>"
        }.joined()

        return #"""
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
            <title>Nudge scheduler simulation · Allen Wang</title>
            <meta name="description" content="A Swift engine that decides which friends to remind you about and when, compared with the rules it replaces over one simulated year.">
            <link rel="icon" href="data:,">
            <meta name="theme-color" content="#f5f5f7" media="(prefers-color-scheme: light)">
            <meta name="theme-color" content="#0b0b0b" media="(prefers-color-scheme: dark)">
            <script>try{var t=localStorage.getItem("theme");if(t==="light"||t==="dark")document.documentElement.setAttribute("data-theme",t)}catch(e){}</script>
            <link rel="stylesheet" href="kit/report.css">
            <style>\#(css)</style>
            <script src="kit/report.js" defer></script>
            <script src="kit/charts.js" defer></script>
            </head>
            <body>
            <a class="skip" href="#main">Skip to content</a>
            <header class="bar"><nav class="wrap" aria-label="Report">
              <a class="back" href="\#(hub)">← Allen Wang</a>
              <span class="title" aria-hidden="true">Nudge scheduler</span>
              <a class="pill" href="\#(repo)">Code ↗</a>
            </nav></header>
            <main id="main">
              <section class="hero wrap" aria-labelledby="h1">
                <p class="eyebrow">Simulation · Swift</p>
                <h1 id="h1">\#(h1)</h1>
                <p class="lede">A Swift package that picks which friends to remind you about and when to send each reminder, played out over one simulated year against a re-implementation of the rules it replaces.</p>
                <p class="conditions"><span class="key">Synthetic: \#(main.contacts.count) invented contacts</span><span class="key">One seed (\#(r.seed)) for the comparison</span><span>Old rules re-implemented from a description</span></p>
                <div class="ratio"><span class="fig">\#(newMax) <span class="hb-unit">vs</span> \#(oldMax)</span><span class="cap">Longest wait in days from falling overdue to the first nudge, any ring: new engine vs old rules, cap \#(r.defaultCap).</span></div>
              </section>

              <section class="wrap" aria-label="Key results">
                <div class="bento">\#(cards)</div>
              </section>

              <section class="s wrap" id="compare" aria-labelledby="h-compare">
                <p class="eyebrow">New engine vs the old rules</p>
                <h2 id="h-compare">\#(compareH2)</h2>
                <p class="lede">The old rules capped how high an overdue friend's priority could climb and let snoozes last forever, so some contacts waited weeks. The engine keeps raising priority and keeps at most one reminder per contact.</p>
                <figure class="figure" aria-labelledby="f-cmp-h">
                  <div class="fig-head"><div><h3 id="f-cmp-h">Every ring's worst case falls from weeks to days</h3><p class="sub">Longest wait (days), including episodes still open at year end · seed \#(r.seed) · cap \#(r.defaultCap) · quiet \#(window(main))</p></div></div>
                  <div id="cmp-plot"></div><div id="cmp-table" hidden></div>
                  <div class="toolbar">\#(viewToggle)</div>
                </figure>
                <figcaption>Wait is days from the first overdue day to the first nudge. The table also gives the number of overdue episodes never nudged by year end. Inner, close and outer friends are due every 10, 20 and 40 days.</figcaption>
                <p class="caveat"><b>One seed, rebuilt baseline.</b> This comparison is a single simulated year (seed \#(r.seed)), and the old rules were re-implemented from a description, not the original code. Read it as a check of the rules, not a measurement of the old app.</p>
              </section>

              <section class="s wrap" id="quiet" aria-labelledby="h-quiet">
                <p class="eyebrow">Quiet hours</p>
                <h2 id="h-quiet">\#(quietH2)</h2>
                <p class="lede">The page uses two quiet windows on purpose. The default, \#(window(main)), crosses midnight; there the old planner put \#(legacy.quietHourViolations) of \#(legacy.deliveries.count) nudges inside quiet hours and the engine none of \#(main.deliveries.count). The old planner's arithmetic assumes the window crosses midnight, so the second window, \#(window(night)), is a stress test that does not.</p>
                <figure class="figure" aria-labelledby="f-q-h">
                  <div class="fig-head"><div><h3 id="f-q-h">With quiet hours \#(window(night)), only the old planner delivers inside the shaded band</h3><p class="sub">Nudges delivered per hour of day over one year · seed \#(r.seed) · cap \#(r.defaultCap)</p></div></div>
                  <div class="hb-pair" id="q-plots">
                    <div><h4>New engine · \#(night.quietHourViolations) of \#(night.deliveries.count) inside</h4><div id="q-new" class="ns-col"></div></div>
                    <div><h4>Old rules · \#(nightOld.quietHourViolations) of \#(nightOld.deliveries.count) inside</h4><div id="q-old" class="ns-col"></div></div>
                  </div>
                  <div id="q-table" hidden></div>
                  <div class="toolbar">\#(viewToggle)</div>
                </figure>
                <figcaption>Bars count deliveries by local hour; the shaded band is the quiet window. Both panels share one y axis. The old rules send fewer nudges in the year (\#(nightOld.deliveries.count) against \#(night.deliveries.count)), so compare shares, not bar heights.</figcaption>
              </section>

              <section class="s wrap" id="cap" aria-labelledby="h-cap">
                <p class="eyebrow">Choosing the daily cap</p>
                <h2 id="h-cap">\#(capH2)</h2>
                <p class="lede">Pooled over \#(r.sweepSeeds) seeds (\#(seeds)), the \#(slow.name) ring's p90 wait is \#(days(p90One)) at cap 1 and \#(days(p90Default)) at cap \#(r.defaultCap). From cap \#(r.defaultCap) up, no ring's p90 exceeds \#(days(worstAbove)), while nudges per day rise only from \#(perDayDefault) to \#(perDayLast).</p>
                <figure class="figure" aria-labelledby="f-cap-h">
                  <div class="fig-head"><div><h3 id="f-cap-h">Waits fall steeply up to cap \#(r.defaultCap), then flatten</h3><p class="sub">\#(r.sweepSeeds) seeds × \#(main.days) days per cap · quiet \#(window(main))</p></div></div>
                  <div class="hb-pair" id="cap-plots">
                    <div><h4>p90 wait by ring</h4><div id="cap-wait"></div></div>
                    <div><h4>Nudges sent per day</h4><div id="cap-day"></div></div>
                  </div>
                  <div id="cap-table" hidden></div>
                  <div class="toolbar">\#(viewToggle)</div>
                </figure>
                <figcaption>p90 wait: 90&#8239;% of overdue episodes, pooled across all seeds, were nudged within this many days. Nudges per day is the mean over seeds, from \#(perDayOne) at cap 1. No per-seed spread is shown.</figcaption>
              </section>

              <section class="s wrap" id="explore" aria-labelledby="h-explore">
                <p class="eyebrow">Explore one cap</p>
                <h2 id="h-explore">\#(exploreH2)</h2>
                <p class="lede">Choose a cap to see its waits and delivery times for seed \#(r.seed).</p>
                <div class="ns-pick"><label for="cap-select">Daily cap</label><select id="cap-select">\#(capOptions)</select><span class="vh" aria-live="polite" id="cap-live"></span></div>
                <figure class="figure" aria-labelledby="f-x-h">
                  <div class="fig-head"><div><h3 id="f-x-h">Waits and delivery times at the selected cap</h3><p class="sub" id="x-sub"></p></div></div>
                  <div class="hb-pair">
                    <div><h4>Wait from overdue to nudge (days)</h4><div id="x-wait"></div></div>
                    <div><h4>Deliveries by hour, quiet \#(window(main)) shaded</h4><div id="x-hours" class="ns-col"></div></div>
                  </div>
                  <div id="x-table" hidden></div>
                  <div class="toolbar">\#(viewToggle)</div>
                </figure>
                <figcaption>Left: each line runs from the median wait (filled dot) to the longest (end of line); the ring marks p90. Right: deliveries per local hour over the year. One simulated year at seed \#(r.seed).</figcaption>
              </section>

              <section class="s wrap" id="method" aria-labelledby="h-method">
                <p class="eyebrow">Methodology</p>
                <h2 id="h-method">How the simulation works</h2>
                <div class="prose" style="margin-top:24px">
                  <p>Each run plays \#(main.days) days of 2026 in America/Los_Angeles for \#(main.contacts.count) invented contacts in four rings. Inner, close and outer friends fall overdue after 10, 20 and 40 days without contact; distant friends never do. The simulated user opens the app once a day at a random minute and replies to a nudge with probability \#(main.replyProbability).</p>
                  <p>The engine and the old rules see the same contacts and random draws. The old rules: a hard cap of \#(legacy.dailyCap), drift priority capped at 80, no per-contact dedupe, snoozes that never expire, and delivery times computed on one calendar day, which assumes quiet hours cross midnight. They were re-implemented from a description, not the original code.</p>
                  <p>The comparison and the cap views use seed \#(r.seed). The cap sweep reruns seeds \#(seeds) at every cap and pools the waits before taking p90. CI reruns the simulation and checks that results.json matches byte for byte.</p>
                </div>
                <div class="two">
                  <div><h3>What this shows</h3><ul>\#(shows.map { "<li>\($0)</li>" }.joined())</ul></div>
                  <div><h3>What it doesn't show</h3><ul>\#(notShows.map { "<li>\($0)</li>" }.joined())</ul></div>
                </div>
              </section>

              <section class="s wrap" id="reproduce" aria-labelledby="h-repro">
                <p class="eyebrow">Reproduce</p>
                <h2 id="h-repro">Run it yourself</h2>
                <div class="codewrap"><pre><code>git clone \#(repo).git
            cd nudge-scheduler
            swift build
            swift test
            swift run -c release nudge-sim --seed \#(r.seed) --out site   # about 55 s</code></pre></div>
                <p style="margin-top:12px;font-size:14px;color:var(--ink-3)">Needs Swift 6 (Xcode 16 or later). No dependencies. Raw output: <a href="results.json" style="text-decoration:underline">results.json</a>.</p>
                <details>
                  <summary>Simulation settings · \#(env.count) rows</summary>
                  <div class="tablewrap" tabindex="0" role="region" aria-label="Simulation settings"><table><thead><tr><th scope="col">Setting</th><th scope="col">Value</th></tr></thead><tbody>\#(envRows)</tbody></table></div>
                </details>
              </section>
            </main>
            <footer><div class="wrap"><span><a href="\#(hub)">← Allen Wang</a><a href="\#(repo)">Code ↗</a></span><span>Generated from commit <span class="mono">\#(String(sha.prefix(7)))</span> · seed \#(r.seed)</span></div></footer>
            <script type="application/json" id="ns-data">\#(json(r))</script>
            <script>\#(script)</script>
            </body>
            </html>

            """#
    }

    static let viewToggle =
        #"<div class="seg" role="radiogroup" aria-label="View" data-ns-view><button role="radio" aria-checked="true" data-value="chart">Chart</button><button role="radio" aria-checked="false" data-value="table">Table</button></div>"#

    static func card(_ label: String, _ value: String, _ unit: String, _ cmp: String, _ foot: String, _ href: String) -> String {
        #"<a class="card span-4" href="\#(href)"><span class="label">\#(label)</span><span class="metric num">\#(value) <span class="unit">\#(unit)</span></span><span class="cmp">\#(cmp)</span><span class="foot">\#(foot)</span></a>"#
    }

    // Ring colours: not kit slots 1/2, which mean "new engine" and "old rules" on this page.
    // Aqua, magenta and yellow pass the dataviz palette validator (all pairs, light and dark);
    // yellow is below 3:1 on white, so every chart has a table view.
    static let css = #"""
        :root{--ns-inner:#1baf7a;--ns-close:#c2449a;--ns-outer:#eda100;--ns-quiet:#ececf0}
        @media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--ns-inner:#199e70;--ns-close:#c255b0;--ns-outer:#c98500;--ns-quiet:#2c2c2e}}
        :root[data-theme="dark"]{--ns-inner:#199e70;--ns-close:#c255b0;--ns-outer:#c98500;--ns-quiet:#2c2c2e}
        .hero .ratio .fig{white-space:nowrap}
        .hb-unit{font-size:.4em;color:var(--ink-2);font-weight:600;vertical-align:middle}
        .hb-pair{display:grid;grid-template-columns:1fr 1fr;gap:24px;margin-top:8px}
        .hb-pair h4{font-size:14px;font-weight:600;color:var(--ink-2);margin:12px 0 0}
        @media (max-width:767px){.hb-pair{grid-template-columns:1fr;gap:8px}}
        .ns-col svg{display:block;width:100%;height:auto}
        .ns-col text{font-family:var(--font-sans);fill:var(--ink-3);font-size:var(--fs-tick);font-variant-numeric:tabular-nums}
        .ns-pick{display:flex;flex-wrap:wrap;align-items:center;gap:12px;margin-top:24px;font-size:15px;font-weight:600}
        .ns-pick select{font:inherit;font-weight:500;min-height:44px;padding:0 12px;border-radius:var(--radius-input);border:1px solid var(--hairline);background:var(--surface-1);color:var(--ink-1)}
        h1,h2,h3{overflow-wrap:break-word}
        /* Kit charts.js never draws narrower than 260 px; keep the figure's inner width above that at 320 px. */
        @media (max-width:359px){.figure{padding-left:12px;padding-right:12px}}
        """#

    static let script = #"""
        addEventListener("DOMContentLoaded", function () {
          var D = RK.data("ns-data"), RC = ["var(--ns-inner)", "var(--ns-close)", "var(--ns-outer)"];
          var cap = function (s) { return s.charAt(0).toUpperCase() + s.slice(1); };
          var hh = function (m) { return (m / 60 < 10 ? "0" : "") + Math.floor(m / 60) + ":00"; };
          // View toggles: show the figure's plots or its table.
          document.querySelectorAll("[data-ns-view]").forEach(function (seg) {
            var fig = seg.closest(".figure");
            RK.segmented(seg, function (v) {
              Array.prototype.forEach.call(fig.children, function (c) {
                if (c.classList.contains("fig-head") || c.classList.contains("toolbar")) return;
                var isTable = /-table$/.test(c.id); c.hidden = (v === "table") !== isTable;
              });
            });
          });
          // Hour-of-day column chart, drawn at real pixel width (text never scales below 12 px).
          function cols(el, o) {
            el = typeof el === "string" ? document.getElementById(el) : el;
            function draw() {
              var W = Math.max(240, el.clientWidth || 600); if (W === el._w) return; el._w = W;
              var narrow = W < 480, H = Math.round(Math.min(260, Math.max(180, W * 0.5))), L = 36, R = 8, T = 10, B = 40;
              var top = o.ymax, step = top <= 40 ? 10 : top <= 100 ? 25 : top <= 200 ? 50 : 100; top = Math.ceil(top / step) * step;
              var bw = (W - L - R) / 24, y = function (v) { return T + (H - T - B) * (1 - v / top); };
              var s = '<svg viewBox="0 0 ' + W + " " + H + '" width="' + W + '" height="' + H + '" role="img" aria-label="' + o.title + '">';
              for (var h = 0; h < 24; h++) if (o.quietAt(h)) s += '<rect x="' + (L + h * bw) + '" y="' + T + '" width="' + bw + '" height="' + (H - T - B) + '" fill="var(--ns-quiet)"/>';
              for (var v = 0; v <= top; v += step) s += '<line x1="' + L + '" x2="' + (W - R) + '" y1="' + y(v) + '" y2="' + y(v) + '" stroke="var(--grid)"/><text x="' + (L - 6) + '" y="' + (y(v) + 4) + '" text-anchor="end">' + v + "</text>";
              o.counts.forEach(function (c, h) { if (!c) return; var x = L + h * bw + 1, w = Math.max(1, bw - 2);
                s += '<rect x="' + x + '" y="' + y(c) + '" width="' + w + '" height="' + (y(0) - y(c)) + '" rx="2" fill="' + o.color + '"><title>' + hh(h * 60) + "–" + hh(h * 60 + 60) + ": " + c + " deliveries" + (o.inside[h] ? ", " + o.inside[h] + " inside quiet hours" : "") + "</title></rect>"; });
              for (var t = 0; t < 24; t += narrow ? 6 : 3) s += '<text x="' + (L + t * bw + bw / 2) + '" y="' + (H - B + 16) + '" text-anchor="middle">' + t + "</text>";
              s += '<text x="' + (L + (W - L - R) / 2) + '" y="' + (H - 4) + '" text-anchor="middle">Hour of day (local)</text></svg>';
              el.innerHTML = s;
            }
            el._draw = draw; el._w = 0; draw();
            if (!el._ro && "ResizeObserver" in window) { el._ro = new ResizeObserver(function () { clearTimeout(el._t); el._t = setTimeout(function () { el._draw(); }, 100); }); el._ro.observe(el); }
          }
          function quietFn(q) { return function (h) { var m = h * 60; return q[0] > q[1] ? (m >= q[0] || m < q[1]) : (m >= q[0] && m < q[1]); }; }
          function hourRows(label, run) { return run.hours.map(function (c, h) { return { k: label, h: hh(h * 60) + "–" + hh(h * 60 + 60), c: c, i: run.inside[h] }; }).filter(function (r) { return r.c; }); }
          var hourCols = [{ key: "k", label: "Run" }, { key: "h", label: "Hour" }, { key: "c", label: "Deliveries" }, { key: "i", label: "Inside quiet hours" }];

          // 1. Before / after
          var S2 = [{ key: "n", name: "New engine", color: "var(--series-1)" }, { key: "o", name: "Old rules", color: "var(--series-2)" }];
          RKCharts.hbar("#cmp-plot", { series: S2, unit: "days", title: "Longest wait by ring, new engine vs old rules", format: function (v) { return String(Math.round(v)); },
            rows: D.rings.map(function (r, i) { return { label: cap(r), values: { n: D.caps[D.defaultCap - 1].rings[i].max, o: D.legacy.rings[i].max } }; }) });
          RKCharts.table("#cmp-table", { caption: "Seed " + D.seed + ", cap " + D.defaultCap + ", quiet 22:00–08:00", columns: [{ key: "r", label: "Ring" }, { key: "a", label: "Longest wait, new (days)" }, { key: "b", label: "Longest wait, old" }, { key: "c", label: "Never nudged, new" }, { key: "d", label: "Never nudged, old" }],
            rows: D.rings.map(function (r, i) { var n = D.caps[D.defaultCap - 1].rings[i], o = D.legacy.rings[i]; return { r: cap(r), a: n.max, b: o.max, c: n.never, d: o.never }; }) });

          // 2. Quiet hours, stress window
          var qmax = Math.max.apply(null, D.night.hours.concat(D.nightLegacy.hours)), qf = quietFn(D.night.quiet);
          cols("q-new", { counts: D.night.hours, inside: D.night.inside, color: "var(--series-1)", ymax: qmax, quietAt: qf, title: "New engine deliveries by hour" });
          cols("q-old", { counts: D.nightLegacy.hours, inside: D.nightLegacy.inside, color: "var(--series-2)", ymax: qmax, quietAt: qf, title: "Old rules deliveries by hour" });
          RKCharts.table("#q-table", { caption: "Deliveries by hour, quiet " + hh(D.night.quiet[0]) + "–" + hh(D.night.quiet[1]), columns: hourCols, rows: hourRows("New engine", D.night).concat(hourRows("Old rules", D.nightLegacy)) });

          // 3. Cap sweep (pooled seeds)
          var caps = D.pooled.map(function (p) { return p.cap; }), intf = function (v) { return String(Math.round(v * 100) / 100); };
          RKCharts.line("#cap-wait", { x: caps, xTicks: caps, xLabel: "Daily cap", yLabel: "p90 wait (days)", yUnit: "days", endLabels: false, height: 260, format: intf, xFormat: intf,
            series: D.rings.map(function (r, i) { return { key: r, name: cap(r), color: RC[i], y: D.pooled.map(function (p) { return p.p90[i]; }) }; }),
            title: "p90 wait by daily cap" });
          RKCharts.line("#cap-day", { x: caps, xTicks: caps, xLabel: "Daily cap", yLabel: "Nudges per day", endLabels: false, height: 260, format: intf, xFormat: intf,
            series: [{ key: "d", name: "Nudges per day", color: "var(--ink-2)", y: D.pooled.map(function (p) { return p.perDay; }) }], title: "Nudges per day by daily cap" });
          RKCharts.table("#cap-table", { caption: D.sweepSeeds + " seeds pooled per cap", columns: [{ key: "c", label: "Cap" }].concat(D.rings.map(function (r, i) { return { key: "p" + i, label: cap(r) + " p90 (days)" }; }), D.rings.map(function (r, i) { return { key: "m" + i, label: cap(r) + " max" }; }), [{ key: "d", label: "Nudges / day" }]),
            rows: D.pooled.map(function (p) { var o = { c: p.cap, d: p.perDay.toFixed(2) }; p.p90.forEach(function (v, i) { o["p" + i] = v; o["m" + i] = p.max[i]; }); return o; }) });

          // 4. Explore one cap: one persistent element per cap (kit charts keep a ResizeObserver on their element).
          var LS = [{ key: "w", name: "Wait", color: "var(--series-1)" }], waitHost = document.getElementById("x-wait"), hourEl = document.getElementById("x-hours");
          var hmax = Math.max.apply(null, D.caps.map(function (c) { return Math.max.apply(null, c.hours); }));
          function show(c) {
            var run = D.caps[c - 1], id = "x-wait-" + c, el = document.getElementById(id);
            if (!el) { el = document.createElement("div"); el.id = id; waitHost.appendChild(el); }
            Array.prototype.forEach.call(waitHost.children, function (k) { k.hidden = k !== el; });
            if (!el._done) { el._done = true;
              RKCharts.dotRange(el, { series: LS, xLabel: "Days from overdue to first nudge", xmin: 0, ticks: { step: 1 }, format: function (v) { return String(v); }, title: "Wait by ring at cap " + c,
                rows: D.rings.map(function (r, i) { var g = run.rings[i]; return { label: cap(r), series: { w: { lo: g.median, mid: g.median, hi: g.max, mark: g.p90, tip: "median " + g.median + " · p90 " + g.p90 + " · longest " + g.max + " days" } } }; }) }); }
            cols(hourEl, { counts: run.hours, inside: run.inside, color: "var(--series-1)", ymax: hmax, quietAt: quietFn(run.quiet), title: "Deliveries by hour at cap " + c });
            RKCharts.table("#x-table", { caption: "Cap " + c + ", seed " + D.seed, columns: [{ key: "r", label: "Ring" }, { key: "a", label: "Median wait (days)" }, { key: "b", label: "p90" }, { key: "m", label: "Longest" }, { key: "n", label: "Never nudged" }, { key: "e", label: "Episodes" }],
              rows: D.rings.map(function (r, i) { var g = run.rings[i]; return { r: cap(r), a: g.median, b: g.p90, m: g.max, n: g.never, e: g.episodes }; }) });
            var tableOn = document.querySelector("#explore [data-ns-view] [aria-checked='true']").dataset.value === "table";
            document.getElementById("x-table").hidden = !tableOn;
            document.getElementById("x-sub").textContent = run.deliveries + " deliveries, " + run.violations + " inside quiet hours · " + run.perDay.toFixed(2) + " nudges per day · cap " + c;
            document.getElementById("cap-live").textContent = "Showing cap " + c + ".";
          }
          var sel = document.getElementById("cap-select");
          try { var q = +new URLSearchParams(location.search).get("cap"); if (q >= 1 && q <= D.caps.length) sel.value = String(q); } catch (e) {}
          sel.addEventListener("change", function () { show(+sel.value); try { var u = new URL(location.href); u.searchParams.set("cap", sel.value); history.replaceState(null, "", u); } catch (e) {} });
          show(+sel.value);
        });
        """#
}
