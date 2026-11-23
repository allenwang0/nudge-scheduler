"""Build site/index.html (and the README results block) from the committed
simulator output site/results.json and its run record site/run.json.

Usage:
  python3 scripts/build_report.py [--results site/results.json]
      [--run site/run.json] [--out site/index.html] [--readme README.md]

Python 3.10+ standard library only. nudge-sim (Swift) is the single source of
the numbers; this script only reads results.json and constants in the committed
Swift sources, so every number on the page is computed, none typed by hand.
Page components and charts come from the vendored report kit in report-kit/.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "report-kit"))
import report_kit as rk  # noqa: E402
from report_kit import Raw, esc, coord, svg_text  # noqa: E402

REPO = "allenwang0/nudge-scheduler"
REPO_URL = f"https://github.com/{REPO}"
PAGE_URL = "https://allenwang0.github.io/nudge-scheduler/"
HOME_URL = "https://allenwang0.github.io/"
RINGS = ["inner", "close", "outer"]  # drift rings, Ring rawValue 0, 1, 2
README_START = "<!-- results:start -->"
README_END = "<!-- results:end -->"
EN = "–"

# Local styles the kit does not have yet (listed as kit requests): two-row chart labels.
LOCAL_CSS = """
.c-band-accent { fill: var(--accent); fill-opacity: .16; }
"""


# ---------------------------------------------------------------- inputs

def load(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def source(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def find_int(rel, pattern):
    match = re.search(pattern, source(rel))
    if not match:
        raise ValueError(f"{pattern!r} not found in {rel}")
    return int(match.group(1))


def find_float(rel, pattern):
    match = re.search(pattern, source(rel))
    if not match:
        raise ValueError(f"{pattern!r} not found in {rel}")
    return float(match.group(1))


def line_range(rel, start, end=None):
    """1-based line numbers of the first line containing `start` and the next containing `end`."""
    lines = source(rel).splitlines()
    first = next(i for i, line in enumerate(lines, 1) if start in line)
    if end is None:
        return first, first
    last = next(i for i, line in enumerate(lines, 1) if i >= first and end in line)
    return first, last


def facts_from_sources():
    """Constants the page quotes, read from the Swift sources at this commit."""
    prop = "Tests/NudgeSchedulerTests/PropertyTests.swift"
    sim = "Sources/NudgeScheduler/Simulation.swift"
    sizes = dict(re.findall(r"\(\.(\w+), (\d+)\)", re.search(r"ringSizes[^\n]+", source(sim)).group(0)))
    cadence = dict(re.findall(r"case \.(inner|close|outer): (\d+)", source("Sources/NudgeScheduler/Model.swift")))
    test_names = re.findall(r"@Test", "".join(source(f"Tests/NudgeSchedulerTests/{n}")
                                              for n in ("DeliveryTests.swift", "EngineTests.swift",
                                                        "PropertyTests.swift", "SimulationTests.swift")))
    return {
        "start_hours": find_int(prop, r"arguments: 0\.\.<(\d+)\)\n\s+func deliveryInvariants"),
        "end_hours": find_int(prop, r"for endHour in 0\.\.<(\d+)"),
        "max_count": find_int(prop, r"for count in 1\.\.\.(\d+)"),
        "draws": find_int(prop, r"for _ in 0\.\.<(\d+) \{\n\s+let now = Self\.dstInstants"),
        "dst_days": find_int(prop, r"\(0\.\.<\((\d+) \* 96\)\)"),
        "grid_minutes": find_int(prop, r"\$0 \* (\d+) \* 60"),
        "lead": find_int("Sources/NudgeScheduler/DeliveryPlanner.swift", r"leadMinutes = (\d+)"),
        "spacing": find_int("Sources/NudgeScheduler/DeliveryPlanner.swift", r"preferredSpacingMinutes = (\d+)"),
        "contacts": sum(int(v) for v in sizes.values()),
        "sizes": {k: int(v) for k, v in sizes.items()},
        "cadence": {k: int(v) for k, v in cadence.items()},
        "snooze": find_float(sim, r"snoozeProbability = ([\d.]+)"),
        "snooze_days": find_int("Sources/NudgeScheduler/Snoozes.swift", r"defaultDays = (\d+)"),
        "drift_base": find_int("Sources/NudgeScheduler/NudgeEngine.swift", r"driftBase = (\d+)"),
        "drift_bonus": find_int("Sources/NudgeScheduler/NudgeEngine.swift", r"driftMaxBonus = (\d+)"),
        "birthday": find_int("Sources/NudgeScheduler/NudgeEngine.swift", r"birthdayToday = (\d+)"),
        "legacy_bonus": find_int("Sources/NudgeScheduler/LegacyBaseline.swift", r"min\(overdue, (\d+)\)"),
        "legacy_cap": find_int("Sources/NudgeScheduler/LegacyBaseline.swift", r"fixedCap = (\d+)"),
        "tests": len(test_names),
    }


def git_last_commit(rel):
    try:
        out = subprocess.run(["git", "log", "-1", "--format=%H", "--", rel], cwd=ROOT, capture_output=True,
                             text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return out or None


# ---------------------------------------------------------------- derived numbers

def hhmm(minute):
    return f"{minute // 60:02d}:{minute % 60:02d}"


def window(run):
    return f"{hhmm(run['quietStartMinute'])}{EN}{hhmm(run['quietEndMinute'])}"


def never(run):
    by = {s["ring"]: s["censored"] for s in run["rings"]}
    return [by[i] for i in range(len(RINGS))]


def derive(r, facts):
    """Every number the page and README show, computed from results.json."""
    cap = r["defaultCap"]
    main, night = r["sweep"][cap - 1], r["nightShift"]
    legacy, night_legacy = r["legacy"], r["nightShiftLegacy"]
    pooled = r["pooledSweep"]
    at_cap = pooled[cap - 1]
    seeds = r["sweepSeeds"]
    ours = [main, night]
    bad = [d["minuteOfDay"] for d in night_legacy["deliveries"] if d["insideQuietHours"]]
    common = max(sorted(set(bad)), key=bad.count) if bad else None
    return {
        "cap": cap,
        "seed": r["seed"],
        "seeds": seeds,
        "seed_last": r["seed"] + seeds - 1,
        "days": main["days"],
        "reply": main["replyProbability"],
        "main": main,
        "night": night,
        "legacy": legacy,
        "night_legacy": night_legacy,
        "both_total": sum(len(x["deliveries"]) for x in ours),
        "both_violations": sum(x["quietHourViolations"] for x in ours),
        "pooled_total": sum(p["deliveries"] for p in pooled),
        "pooled_violations": sum(p["quietHourViolations"] for p in pooled),
        "pooled_runs": seeds * len(pooled),
        "caps": [p["cap"] for p in pooled],
        "pairs": facts["start_hours"] * facts["end_hours"],
        "plans_per_pair": facts["max_count"] * facts["draws"],
        "p90": at_cap["allDrift"]["p90Wait"],
        "max": at_cap["allDrift"]["maxWait"],
        "seed_max_lo": min(s["maxWait"] for s in at_cap["perSeed"]),
        "seed_max_hi": max(s["maxWait"] for s in at_cap["perSeed"]),
        "seed_p90_lo": min(s["p90Wait"] for s in at_cap["perSeed"]),
        "seed_p90_hi": max(s["p90Wait"] for s in at_cap["perSeed"]),
        "p90_cap1": pooled[0]["allDrift"]["p90Wait"],
        "max_cap1": pooled[0]["allDrift"]["maxWait"],
        "max_above": max(p["allDrift"]["maxWait"] for p in pooled[cap:]),
        "max_above_lo": min(p["allDrift"]["maxWait"] for p in pooled[cap:]),
        "episodes": sum(s["episodes"] for s in at_cap["rings"]),
        "open": sum(s["neverNudged"] for s in at_cap["rings"]),
        "rate_cap": at_cap["meanNudgesPerDay"],
        "rate_cap1": pooled[0]["meanNudgesPerDay"],
        "volume": night["meanNudgesPerDay"] / night_legacy["meanNudgesPerDay"],
        "volume_default": main["meanNudgesPerDay"] / legacy["meanNudgesPerDay"],
        "legacy_bad_mode": common,
        "legacy_bad_range": (min(bad), max(bad)) if bad else None,
    }


def days(n):
    return rk.num(n, "day" if n == 1 else "days")


def count(n):
    return f"{n:,}"


def share(bad, total):
    if bad == 0:
        return "0%"
    v = bad / total * 100
    return f"{v:.1f}%" if v < 10 else f"{v:.0f}%"


def span(lo, hi, unit=""):
    return f"{lo}{unit}" if lo == hi else f"{lo}{EN}{hi}{unit}"


# ---------------------------------------------------------------- charts

def histogram_chart(rows, *, uid, width, title, desc, bin_minutes=30, compact=False):
    """Deliveries per time-of-day bin, one small multiple per row, quiet hours shaded.

    rows: dicts with name, detail, minutes (list), quiet (start, end), accent, note (optional).
    """
    phone = width < 420
    nb = 1440 // bin_minutes
    counts = []
    for row in rows:
        c = [0] * nb
        for m in row["minutes"]:
            c[m // bin_minutes] += 1
        counts.append(c)
    top_count = max(max(c) for c in counts)
    yt = rk.nice_ticks(0, top_count, 3)
    ymax = yt[-1]
    ml, mr = (0 if compact else 34), 8
    plot_w = width - ml - mr
    two_line = phone or compact
    head = 46 if two_line else 32
    plot_h = 44 if compact else 64
    gap = 18 if compact else 26
    x = lambda minute: ml + plot_w * minute / 1440
    parts = []
    y = 0
    for row, c in zip(rows, counts):
        if two_line:
            parts.append(svg_text(0, y + 13, row["name"], "c-value"))
            parts.append(svg_text(0, y + 30, row["detail"], "c-label"))
        else:
            parts.append(svg_text(0, y + 14, row["name"], "c-value"))
            if row["detail"]:
                parts.append(svg_text(width, y + 14, row["detail"], "c-label", "end"))
        top = y + head
        base = top + plot_h
        qs, qe = row["quiet"]
        spans = [(qs, qe)] if qs < qe else [(0, qe), (qs, 1440)]
        for a, b in spans:
            parts.append(f'<rect class="c-band" x="{coord(x(a))}" y="{coord(top - 4)}" width="{coord(x(b) - x(a))}" '
                         f'height="{coord(plot_h + 4)}"/>')
        qx = x(qs) + 5 if qs < qe else x(0) + 5
        parts.append(svg_text(qx, top + 9, "quiet", "c-tick"))
        for t in yt[1:]:
            ty = base - plot_h * t / ymax
            parts.append(f'<path class="c-grid" d="M{ml} {coord(ty)}H{coord(width - mr)}"/>')
            if not compact:
                parts.append(svg_text(ml - 6, ty + 4, f"{t:g}", "c-tick", "end"))
        bw = plot_w / nb
        cls = "c-accent" if row["accent"] else "c-muted"
        for i, v in enumerate(c):
            if v == 0:
                continue
            h = plot_h * v / ymax
            parts.append(f'<rect class="{cls}" x="{coord(ml + i * bw + 0.5)}" y="{coord(base - h)}" '
                         f'width="{coord(max(bw - 1, 1))}" height="{coord(h)}"/>')
        parts.append(f'<path class="c-axis" d="M{ml} {coord(base)}H{coord(width - mr)}"/>')
        if row.get("note") and not phone:
            nx, label = row["note"]
            parts.append(f'<path class="c-line" d="M{coord(x(nx))} {coord(top + 18)}V{coord(top + 26)}"/>')
            parts.append(svg_text(x(nx) + 6, top + 22, label, "c-label"))
        y = base + gap
    step = 360 if phone or compact else 180
    for m in range(0, 1441, step):
        parts.append(svg_text(x(m), y - gap + 16, hhmm(m % 1440 if m < 1440 else 0) if m < 1440 else "24:00",
                              "c-tick", "middle" if 0 < m < 1440 else ("start" if m == 0 else "end")))
    height = y - gap + 22
    if not compact:
        parts.append(svg_text(ml, height + 14, f"Local time ({bin_minutes}-minute bins)", "c-title"))
        height += 22
    return rk.svg(uid, width, height, title, desc, "".join(parts))


def sweep_chart(pooled, cap, *, uid, width, title, desc):
    """p90 and max wait vs daily cap: pooled line (accent) over the per-seed min-max band."""
    phone = width < 520
    metrics = [("p90Wait", "p90 wait"), ("maxWait", "Longest wait")]
    panel_w = width if phone else (width - 40) / 2
    panel_h = 200 if phone else 240
    parts = []
    for k, (key, name) in enumerate(metrics):
        ox = 0 if phone else k * (panel_w + 40)
        oy = k * (panel_h + 36) if phone else 0
        lo = [min(s[key] for s in p["perSeed"]) for p in pooled]
        hi = [max(s[key] for s in p["perSeed"]) for p in pooled]
        val = [p["allDrift"][key] for p in pooled]
        caps = [p["cap"] for p in pooled]
        yt = rk.nice_ticks(0, max(hi), 5)
        ml, mt, mb, mr = 30, 30, 34, 14
        px = lambda c: ox + ml + (panel_w - ml - mr) * (c - caps[0]) / (caps[-1] - caps[0])
        py = lambda v: oy + panel_h - mb - (panel_h - mt - mb) * v / yt[-1]
        parts.append(svg_text(ox, oy + 14, f"{name} (days)", "c-value"))
        for t in yt:
            parts.append(f'<path class="c-grid" d="M{coord(ox + ml)} {coord(py(t))}H{coord(ox + panel_w - mr)}"/>')
            parts.append(svg_text(ox + ml - 6, py(t) + 4, f"{t:g}", "c-tick", "end"))
        band = "".join(("M" if i == 0 else "L") + f"{coord(px(c))} {coord(py(h))}" for i, (c, h) in enumerate(zip(caps, hi)))
        band += "".join(f"L{coord(px(c))} {coord(py(v))}" for c, v in reversed(list(zip(caps, lo)))) + "Z"
        parts.append(f'<path class="c-band-accent" d="{band}"/>')
        parts.append(f'<path class="c-floor" d="M{coord(px(cap))} {coord(py(yt[-1]) - 4)}V{coord(py(0))}"/>')
        line = "".join(("M" if i == 0 else "L") + f"{coord(px(c))} {coord(py(v))}" for i, (c, v) in enumerate(zip(caps, val)))
        parts.append(f'<path class="c-line-accent" stroke-width="2" d="{line}"/>')
        for c, v in zip(caps, val):
            parts.append(f'<circle cx="{coord(px(c))}" cy="{coord(py(v))}" r="3.5" class="c-accent"/>')
        v3 = val[cap - caps[0]]
        parts.append(svg_text(px(cap) + 8, py(v3) - 10, f"cap {cap}: {days(v3)}", "c-label c-hi"))
        parts.append(f'<path class="c-axis" d="M{coord(ox + ml)} {coord(py(0))}H{coord(ox + panel_w - mr)}"/>')
        for c in caps:
            if phone and c % 3 != 1 and c != caps[-1]:
                continue
            parts.append(svg_text(px(c), py(0) + 16, str(c), "c-tick", "middle"))
        parts.append(svg_text(ox + panel_w - mr, py(0) + 30, "Daily cap", "c-title", "end"))
    height = (2 * panel_h + 36) if phone else panel_h
    return rk.svg(uid, width, height, title, desc, "".join(parts))


# ---------------------------------------------------------------- page pieces

def hist_rows(d, with_legacy):
    main, night, nl = d["main"], d["night"], d["night_legacy"]
    def row(run, name, accent, note=None):
        n, bad = len(run["deliveries"]), run["quietHourViolations"]
        return {"name": name, "detail": f"{count(n)} deliveries, {count(bad)} in quiet hours",
                "minutes": [x["minuteOfDay"] for x in run["deliveries"]],
                "quiet": (run["quietStartMinute"], run["quietEndMinute"]), "accent": accent, "note": note}
    rows = [row(main, f"This package · quiet {window(main)}", True),
            row(night, f"This package · quiet {window(night)}", True)]
    if with_legacy:
        rows.append(row(nl, f"Legacy rules · quiet {window(nl)}", False,
                        (d["legacy_bad_mode"], f"{count(nl['quietHourViolations'])} inside") if d["legacy_bad_mode"] else None))
    return rows


def hist_table(d):
    runs = [d["main"], d["night"], d["night_legacy"]]
    head = ["Hour", f"Package, quiet {window(d['main'])}", f"Package, quiet {window(d['night'])}",
            f"Legacy, quiet {window(d['night_legacy'])}"]
    out = []
    for h in range(24):
        out.append([f"{h:02d}:00"] + [str(sum(1 for x in r["deliveries"] if x["minuteOfDay"] // 60 == h)) for r in runs])
    return rk.data_table("Deliveries per hour of day, seed " + str(d["seed"]), head, out, numeric={1, 2, 3})


def evidence_rows(d, facts, src_sha, res_sha):
    def blob(rel, sha, start=None, end=None):
        anchor = f"#L{start}" + (f"-L{end}" if end and end != start else "") if start else ""
        return f"{REPO_URL}/blob/{sha}/{rel}{anchor}"
    res = blob("site/results.json", res_sha)
    prop = "Tests/NudgeSchedulerTests/PropertyTests.swift"
    inv = line_range(prop, "static let dstInstants", "if i > 0")
    simt = "Tests/NudgeSchedulerTests/SimulationTests.swift"
    det = line_range(simt, "byte-identical JSON", "!= Simulation.encode")
    leg = line_range("Sources/NudgeScheduler/LegacyBaseline.swift", "/// Spreads deliveries", "return (0..<count)")
    plan = line_range("Sources/NudgeScheduler/DeliveryPlanner.swift", "static func window", "return (start, end)")
    sim = line_range("Sources/NudgeScheduler/Simulation.swift", "public var replyProbability", "startDate =")
    sweep = line_range("Sources/nudge-sim/Results.swift", "struct WaitStats", "quietHourViolations = runs")
    main, night = d["main"], d["night"]
    return [
        ("E1", f"{count(len(main['deliveries']))} deliveries with quiet hours {window(main)} and "
               f"{count(len(night['deliveries']))} with {window(night)}, none inside quiet hours; seed {d['seed']}, cap {d['cap']}",
         f"site/results.json: sweep[{d['cap'] - 1}] (cap {d['cap']}), nightShift", res, "Measured"),
        ("E2", f"{count(d['pooled_total'])} deliveries over {d['pooled_runs']} simulated years "
               f"({d['seeds']} seeds × caps {d['caps'][0]}{EN}{d['caps'][-1]}), {count(d['pooled_violations'])} inside quiet hours",
         "site/results.json: pooledSweep[].deliveries, quietHourViolations", res, "Measured"),
        ("E3", f"All {d['pairs']} quiet-hour start/end hour pairs, {d['plans_per_pair']} delivery plans each, "
               f"timed within {rk.num(facts['dst_days'], 'days')} of both 2026 clock changes",
         f"{prop}:{inv[0]}{EN}{inv[1]}", blob(prop, src_sha, *inv), "Test"),
        ("E4", f"Cap {d['cap']}: p90 wait {days(d['p90'])}, longest {days(d['max'])}, pooled over {d['seeds']} seeds; "
               f"per-seed longest {rk.num(span(d['seed_max_lo'], d['seed_max_hi']), 'days')}",
         f"site/results.json: pooledSweep; computed in Sources/nudge-sim/Results.swift:{sweep[0]}{EN}{sweep[1]}", res,
         "Measured"),
        ("E5", "The same seed gives byte-identical results; CI compares a fresh run with the committed file",
         f"{simt}:{det[0]}{EN}{det[1]}; .github/workflows/ci.yml (cmp)", blob(simt, src_sha, *det), "Test"),
        ("E6", f"Legacy rules: {count(d['night_legacy']['quietHourViolations'])} of "
               f"{count(len(d['night_legacy']['deliveries']))} deliveries inside quiet hours {window(d['night_legacy'])}; "
               f"{count(d['legacy']['quietHourViolations'])} of {count(len(d['legacy']['deliveries']))} inside "
               f"{window(d['legacy'])}",
         "site/results.json: nightShiftLegacy, legacy", res, "Measured"),
        ("E7", "The legacy planner spreads reminders from the end of quiet hours to the start on the same day, "
               "which assumes the window wraps midnight; re-implemented from a description",
         f"Sources/NudgeScheduler/LegacyBaseline.swift:{leg[0]}{EN}{leg[1]}",
         blob("Sources/NudgeScheduler/LegacyBaseline.swift", src_sha, *leg), "Code"),
        ("E8", "The planner's allowed window ends the same day only when quiet hours wrap midnight",
         f"Sources/NudgeScheduler/DeliveryPlanner.swift:{plan[0]}{EN}{plan[1]}",
         blob("Sources/NudgeScheduler/DeliveryPlanner.swift", src_sha, *plan), "Code"),
        ("E9", f"Synthetic inputs: {facts['contacts']} invented contacts, reply probability {d['reply']}, "
               f"snooze probability {facts['snooze']}, all assumed",
         f"Sources/NudgeScheduler/Simulation.swift:{sim[0]}{EN}{sim[1]}",
         blob("Sources/NudgeScheduler/Simulation.swift", src_sha, *sim), "Code"),
    ]


def build_page(r, run, results_sha=None):
    facts = facts_from_sources()
    d = derive(r, facts)
    src_sha = run["code_sha"]
    res_sha = results_sha or src_sha
    ev = {row[0]: row for row in evidence_rows(d, facts, src_sha, res_sha)}
    R = rk.ref
    main, night, legacy, nl = d["main"], d["night"], d["legacy"], d["night_legacy"]
    res_href = ev["E1"][3]
    yr = f"{d['days']} simulated days"

    hero_desc = (f"Deliveries by time of day for seed {d['seed']}, cap {d['cap']}: {len(main['deliveries'])} with quiet "
                 f"hours {window(main)} and {len(night['deliveries'])} with {window(night)}; none inside quiet hours.")
    hero_title = "Every reminder landed outside the quiet window"
    hero = rk.hero(
        eyebrow="Swift library · Deterministic simulator",
        title="nudge-scheduler",
        subtitle=Raw("A Swift package that picks which friends to remind you about each day and times each reminder "
                     "outside your quiet hours. It never reads the clock itself, so every run replays exactly."),
        value=f"{count(d['both_total'] - d['both_violations'])} of {count(d['both_total'])}",
        label=Raw(f"simulated reminders landed outside quiet hours, in both windows tested{R('E1')}"),
        support=Raw(f"{count(len(main['deliveries']))} with quiet hours {window(main)} and "
                    f"{count(len(night['deliveries']))} with {window(night)}, one simulated year each. Tests cover all "
                    f"{d['pairs']} quiet-hour start/end pairs around both 2026 clock changes.{R('E3')}"),
        context=f"Synthetic data: {facts['contacts']} invented contacts, seed {d['seed']}, daily cap {d['cap']}, "
                f"2026 in America/Los_Angeles.",
        actions=[("Source", REPO_URL, True), ("Run the simulation", "#reproduce", False)],
        figure=rk.tag("p", f"Deliveries per hour of day, seed {d['seed']}, cap {d['cap']}", class_="card-label")
        + rk.variants(*(histogram_chart(hist_rows(d, False), uid=f"hero-{k}", width=w, title=hero_title, desc=hero_desc,
                                        bin_minutes=60, compact=True)
                        for k, w in (("d", 398), ("t", 640), ("p", 280)))),
    )

    nav = rk.toc([("findings", "Findings"), ("delivery", "Delivery times"), ("legacy", "Legacy rules"),
               ("cap", "Daily cap"), ("how", "How it works"), ("methodology", "Method"),
               ("limitations", "Limits"), ("reproduce", "Reproduce"), ("evidence", "Evidence")])

    findings = rk.bento([
        (8, 1, rk.join([
            rk.tag("h3", f"Quiet hours held across {d['pooled_runs']} simulated years", class_="card-heading"),
            rk.metric("Deliveries inside quiet hours", f"{count(d['pooled_violations'])} of {count(d['pooled_total'])}"),
            rk.tag("p", Raw(f"Quiet hours {window(main)}, {d['seeds']} seeds × every cap from {d['caps'][0]} to "
                            f"{d['caps'][-1]}, {yr} each.{R('E2')}")),
        ])),
        (4, 2, rk.join([
            rk.tag("h3", "Clock changes are tested", class_="card-heading"),
            rk.metric("Quiet-hour start/end pairs", str(d["pairs"])),
            rk.tag("p", Raw(f"Each pair gets {d['plans_per_pair']} delivery plans timed near the March and November "
                            f"2026 changes.{R('E3')}")),
        ])),
        (6, 3, rk.join([
            rk.tag("h3", f"Cap {d['cap']} reaches overdue friends within days", class_="card-heading"),
            rk.metric(f"p90 wait at cap {d['cap']}", str(d["p90"]), "day" if d["p90"] == 1 else "days"),
            rk.tag("p", Raw(f"Longest wait {days(d['max'])}, pooled over {d['seeds']} seeds; at cap 1, "
                            f"{days(d['p90_cap1'])}.{R('E4')} <a href=\"#cap\">Cap sweep</a>")),
        ])),
        (6, 4, rk.join([
            rk.tag("h3", "Same seed, same bytes", class_="card-heading"),
            rk.tag("p", Raw(f"Every call takes the time and calendar as arguments, so a seed replays byte for byte. A "
                            f"test checks it, and CI compares a fresh run with the committed results.{R('E5')}")),
        ])),
    ])
    findings_sec = rk.section("findings", "What the simulation and tests show", findings, eyebrow="Findings")

    # Delivery-time histogram
    hist_desc = (f"Three rows of deliveries per 30 minutes. This package, quiet {window(main)}: "
                 f"{len(main['deliveries'])} deliveries, {main['quietHourViolations']} inside. This package, quiet "
                 f"{window(night)}: {len(night['deliveries'])}, {night['quietHourViolations']} inside. Legacy rules, quiet "
                 f"{window(nl)}: {len(nl['deliveries'])}, {nl['quietHourViolations']} inside.")
    hist_take = f"The package keeps both windows clear; the legacy rules put {nl['quietHourViolations']} reminders inside one"
    hist_fig = rk.figure(
        "fig-delivery", hist_take,
        rk.variants(*(histogram_chart(hist_rows(d, True), uid=f"hist-{k}", width=w, title=hist_take, desc=hist_desc)
                      for k, w in (("d", 1000), ("t", 640), ("p", 300)))),
        rk.tag("p", Raw(
            f"Local delivery time of every reminder in one simulated year, seed {d['seed']}, cap {d['cap']}; shaded: "
            f"quiet hours. The legacy row uses the re-implemented baseline, not the original code.{R('E1')}{R('E6')}")),
        question="At what time of day does each reminder arrive, relative to quiet hours?",
        table=hist_table(d), data_href=res_href,
    )
    lo, hi = d["legacy_bad_range"]
    hist_body = rk.join([
        hist_fig,
        Raw('<div class="prose" style="margin-top:32px">'),
        rk.tag("p", Raw(
            f"The planner starts {rk.num(facts['lead'], 'minutes')} after the app opens and looks for the next allowed window: from "
            f"the end of quiet hours to the next start. That window ends the same day only when quiet hours wrap "
            f"midnight, like {window(main)}; otherwise it runs into the next day.{R('E8')} Reminders are spread evenly "
            f"across what is left of it, at least {rk.num(facts['spacing'], 'minutes')} apart when there is room.")),
        rk.tag("p", Raw(
            f"The legacy rules always spread reminders from the end of quiet hours to the start on the same calendar "
            f"day.{R('E7')} With quiet hours {window(nl)}, that runs backwards from {hhmm(nl['quietEndMinute'])} to "
            f"{hhmm(nl['quietStartMinute'])}, so reminders land between {hhmm(lo)} and {hhmm(hi)} — inside the window.")),
        Raw("</div>"),
    ])
    hist_sec = rk.section("delivery", "Reminders land only in the hours quiet mode allows", hist_body,
                          eyebrow="Result")

    # Legacy comparison table
    def lrow(run, who):
        n, bad = len(run["deliveries"]), run["quietHourViolations"]
        return [Raw(f"{esc(window(run))}"), who, count(n), f"{run['meanNudgesPerDay']:.2f}",
                f"{count(bad)} ({share(bad, n)})", " / ".join(str(v) for v in never(run))]
    cmp_table = rk.table(
        f"This package against the legacy rules, seed {d['seed']}, one simulated year per row",
        ["Quiet hours", "Scheduler", "Deliveries", "Reminders per day", "Inside quiet hours", "Never nudged (inner / close / outer)"],
        [lrow(main, f"This package, cap {d['cap']}"), lrow(legacy, f"Legacy, fixed cap {facts['legacy_cap']}"),
         lrow(night, f"This package, cap {d['cap']}"), lrow(nl, f"Legacy, fixed cap {facts['legacy_cap']}")],
        numeric={2, 3, 4, 5})
    legacy_body = rk.join([
        cmp_table,
        Raw('<div class="prose" style="margin-top:24px">'),
        rk.tag("p", Raw(
            f"Under the default window {window(legacy)} the legacy rules mostly work: {count(legacy['quietHourViolations'])} "
            f"of {count(len(legacy['deliveries']))} deliveries fell inside it. The failure is specific to windows that do "
            f"not wrap midnight, such as a night-shift {window(nl)}.{R('E6')}")),
        rk.tag("p", Raw(
            f"The package also sends {d['volume']:.1f}× as many reminders per day ({night['meanNudgesPerDay']:.2f} vs "
            f"{nl['meanNudgesPerDay']:.2f} with quiet hours {window(night)}), so raw counts are not comparable; the "
            f"share inside quiet hours is. The legacy rules cap drift priority lower (bonus up to "
            f"{rk.num(facts['legacy_bonus'], 'days')} instead of {facts['drift_bonus']}), never expire snoozes and do not dedupe "
            f"contacts, which is consistent with the episodes they never nudge in the last column.")),
        rk.tag("p", Raw(
            f"The baseline was re-implemented from a description of the old behavior, not from its code, and each row "
            f"is a single seed.{R('E7')}")),
        Raw("</div>"),
    ])
    legacy_sec = rk.section("legacy", "The old rules broke quiet hours that do not wrap midnight", legacy_body,
                            eyebrow="Baseline")

    # Cap sweep
    pooled = r["pooledSweep"]
    cap = d["cap"]
    sweep_desc = (f"p90 and longest wait from overdue to first nudge, drift rings pooled over {d['seeds']} seeds, for "
                  f"caps {d['caps'][0]} to {d['caps'][-1]}. Cap 1: p90 {d['p90_cap1']}, longest {rk.num(d['max_cap1'], 'days')}. "
                  f"Cap {cap}: p90 {d['p90']}, longest {d['max']}. Caps above {cap}: longest "
                  f"{rk.num(span(d['max_above_lo'], d['max_above']), 'days')}.")
    sweep_take = (f"Cap {cap} gets 90% of overdue friends a nudge within {days(d['p90'])}; higher caps barely move "
                  f"the longest wait")
    sweep_rows = []
    for p in pooled:
        ps = p["perSeed"]
        sweep_rows.append([str(p["cap"]), str(p["allDrift"]["p90Wait"]),
                           span(min(s["p90Wait"] for s in ps), max(s["p90Wait"] for s in ps)),
                           str(p["allDrift"]["maxWait"]),
                           span(min(s["maxWait"] for s in ps), max(s["maxWait"] for s in ps)),
                           f"{p['meanNudgesPerDay']:.2f}", count(p["deliveries"])])
    sweep_fig = rk.figure(
        "fig-cap", sweep_take,
        rk.variants(*(sweep_chart(pooled, cap, uid=f"cap-{k}", width=w, title=sweep_take, desc=sweep_desc)
                      for k, w in (("d", 1000), ("t", 640), ("p", 300)))),
        rk.tag("p", Raw(
            f"Line: all inner, close and outer episodes pooled over seeds {d['seed']}{EN}{d['seed_last']} "
            f"({count(d['episodes'])} episodes at cap {cap}). Band: lowest to highest value of a single seed. Wait = "
            f"days from the first overdue day to the first nudge; {d['open']} episodes still open at year end count "
            f"at their lower bound. Quiet hours {window(main)}.{R('E4')}")),
        question="How long does an overdue friend wait for a reminder, and how much does the daily cap matter?",
        table=rk.data_table(f"Wait from overdue to first nudge (days), {d['seeds']} seeds per cap",
                            ["Cap", "p90 pooled", "p90 per seed", "Longest pooled", "Longest per seed", "Reminders per day",
                             "Deliveries"], sweep_rows, numeric={1, 2, 3, 4, 5, 6}),
        data_href=res_href,
    )
    cap_body = rk.join([
        sweep_fig,
        Raw('<div class="prose" style="margin-top:32px">'),
        rk.tag("p", Raw(
            f"At cap 1 the queue backs up: p90 {days(d['p90_cap1'])}, longest {days(d['max_cap1'])}. From cap {cap} on, "
            f"the p90 is at most a day and the longest wait stays at {rk.num(span(d['max_above_lo'], d['max_above']), 'days')}, "
            f"because the engine already surfaces every overdue friend most days. Volume rises from "
            f"{d['rate_cap1']:.2f} to {d['rate_cap']:.2f} reminders per day between cap 1 and cap {cap}.")),
        Raw("</div>"),
    ])
    cap_sec = rk.section("cap", f"A daily cap of {cap} keeps waits short without flooding the user", cap_body,
                         eyebrow="Sensitivity")

    # How it works
    how = rk.methodology([
        ("Rings", Raw(f"Inner, close and outer friends are due every {facts['cadence']['inner']}, "
                      f"{facts['cadence']['close']} and {rk.num(facts['cadence']['outer'], 'days')}; distant friends get no drift "
                      f"reminders.")),
        ("Score", Raw(f"An overdue friend scores {facts['drift_base']} plus one point per overdue day, up to "
                      f"{facts['drift_base'] + facts['drift_bonus']}; a birthday today scores {facts['birthday']}.")),
        ("Pick", Raw("One reminder per friend, sorted by score, kind, ring and id, then cut to the daily cap. Output "
                     "does not depend on input order.")),
        ("Place", Raw(f"<code>DeliveryPlanner</code> spaces the day's reminders inside the next allowed window, never "
                      f"sooner than {rk.num(facts['lead'], 'minutes')} after now.{R('E8')}")),
        ("Snooze", Raw(f"A snoozed friend is skipped for {rk.num(facts['snooze_days'], 'days')}, then returns.")),
        ("Inputs", Raw("<code>now</code> and <code>calendar</code> are arguments; the package never reads the system "
                       "clock or time zone.")),
    ])
    how_sec = rk.section("how", "Each day: score overdue friends, keep the top few, place them in allowed hours",
                         how, eyebrow="Mechanism")

    # Methodology
    method = rk.methodology([
        ("Simulator", Raw(f"<code>nudge-sim</code> (Swift, release build) at "
                          f'<a class="src" href="{REPO_URL}/tree/{esc(src_sha)}">{esc(src_sha[:7])}</a>')),
        ("Data", f"Synthetic: {facts['contacts']} invented contacts ({facts['sizes']['inner']} inner, "
                 f"{facts['sizes']['close']} close, {facts['sizes']['outer']} outer, {facts['sizes']['distant']} distant), "
                 f"regenerated from each seed"),
        ("Period", f"{yr} from 2026-01-01, America/Los_Angeles; includes both clock changes"),
        ("User model", f"Opens the app once a day at a random minute; replies to a reminder with probability "
                       f"{d['reply']}, otherwise snoozes with probability {facts['snooze']} (assumptions)"),
        ("Runs", f"Seed {d['seed']} for each scenario; cap sweep seeds {d['seed']}{EN}{d['seed_last']} × caps "
                 f"{d['caps'][0]}{EN}{d['caps'][-1]} = {d['pooled_runs']} runs"),
        ("Quiet hours", f"Default {window(main)}; night shift {window(night)}"),
        ("Wait statistic", "Days from first overdue day to first nudge; p90 is the nearest-rank 90th percentile; "
                           "open episodes counted at their lower bound"),
        ("Tests", f"{facts['tests']} Swift Testing tests (@Test functions); "
                  f"parameterised ones run every argument"),
        ("Machine", f"{run['machine']}, {run['os']}, {run['swift']}; load average {run['load_average_after_run']} "
                    f"after the run. Output does not depend on the machine."),
        ("Run time", f"{rk.num(round(run['wall_seconds']), 's')} for the full run"),
        ("Run date", run["date"]),
    ])
    method_sec = rk.section("methodology", "Methodology", method, eyebrow="Conditions")

    limits = rk.limitations([
        ("Synthetic friends and behavior.", Raw(f"Reply and snooze rates are assumptions, so wait times compare "
                                                f"settings; they do not forecast real use.{R('E9')}")),
        ("Re-implemented baseline.", "The legacy rules were rebuilt from a description, not the original code; a "
                                     "faithful copy could behave differently."),
        ("One seed per scenario.", f"The legacy comparison and the night-shift window use seed {d['seed']} only; the "
                                   f"cap sweep uses {d['seeds']} seeds with the default window."),
        ("Different volumes.", f"The package sends {d['volume']:.1f}× as many reminders as the legacy rules, so compare "
                               f"shares, not counts."),
        ("One time zone.", "Every run uses America/Los_Angeles; other zones' clock changes are not simulated, though "
                           "the planner reads the zone from its calendar argument."),
    ])
    limits_sec = rk.section("limitations", "Results cover one synthetic friend group in one time zone", limits,
                            eyebrow="Limitations")

    steps_html = rk.reproduce([
        (f"Build and run the tests (Swift 6, Xcode 16 or later, macOS; no dependencies). Expect “Test run with "
         f"{facts['tests']} tests”.", "swift build && swift test"),
        (f"Run the simulation (about {rk.num(round(run['wall_seconds']), 's')} here). It rewrites site/results.json and site/card.json; "
         f"with seed {d['seed']} the results file is byte-identical to the committed one.",
         f"swift run -c release nudge-sim --seed {d['seed']} --out site\ngit diff --exit-code site/results.json"),
        ("Rebuild this page and the README block from the results (Python 3.10+, standard library).",
         "python3 scripts/build_report.py --readme README.md"),
        ("Check that the page's numbers match results.json.", "python3 -m unittest discover -s scripts -p 'test_*.py'"),
    ])
    repro_sec = rk.section("reproduce", "Reproduce it in four commands", steps_html, eyebrow="Reproduce",
                           intro=Raw(f'Commands run from a clone of <a class="src" href="{REPO_URL}">{REPO}</a>.'))

    ev_table = rk.table("Evidence ledger", ["ID", "Claim", "Source", "Class"],
                        [[Raw(f'<span id="evidence-{eid.lower()}">{eid}</span>'), claim,
                          Raw(f'<a class="src" href="{esc(href)}">{esc(src)}</a>'), cls]
                         for eid, claim, src, href, cls in ev.values()], wrap_cols={1, 2})
    ev_sec = rk.section("evidence", "Every number traces to a committed file", ev_table, eyebrow="Sources")

    body = rk.join([hero, nav, findings_sec, hist_sec, legacy_sec, cap_sec, how_sec, method_sec, limits_sec,
                    repro_sec, ev_sec])
    footer = rk.footer(
        Raw(f"Generated by <code>scripts/build_report.py</code> from <code>site/results.json</code> · code "
            f"{esc(src_sha[:7])} · run {esc(run['date'])} on {esc(run['machine'])}"),
        Raw(f'<a href="{HOME_URL}">Allen Wang</a> · <a href="{REPO_URL}">Source</a>'))
    html = rk.page(
        title="nudge-scheduler · Allen Wang",
        description=(f"A Swift reminder scheduler: {count(d['both_total'])} of {count(d['both_total'])} simulated "
                     f"reminders landed outside quiet hours in two windows, with clock changes covered by tests."),
        canonical=PAGE_URL,
        header=rk.report_header(HOME_URL, "← Allen Wang", [("Source", REPO_URL)]),
        main=body, footer=footer)
    return html.replace("</style>", LOCAL_CSS + "</style>", 1)


# ---------------------------------------------------------------- README

def readme_block(r):
    d = derive(r, facts_from_sources())
    main, night, nl, legacy = d["main"], d["night"], d["night_legacy"], d["legacy"]
    return "\n".join([
        README_START,
        f"- **{count(d['both_total'])} of {count(d['both_total'])} simulated reminders landed outside quiet hours**: "
        f"{count(len(main['deliveries']))} with quiet hours {window(main)} and {count(len(night['deliveries']))} with "
        f"{window(night)} (seed {d['seed']}, cap {d['cap']}).",
        f"- **Clock changes are tested**: all {d['pairs']} quiet-hour start/end pairs around both 2026 "
        f"daylight-saving changes; the same seed gives byte-identical output.",
        f"- **Short waits at the default cap of {d['cap']}**: 90% of overdue friends get a reminder within "
        f"{days(d['p90'])}, the longest wait is {days(d['max'])} ({d['seeds']} seeds pooled).",
        f"- **Against the old rules** (re-implemented from a description): with quiet hours {window(nl)} they put "
        f"{nl['quietHourViolations']} of {len(nl['deliveries'])} reminders inside the window; with {window(legacy)}, "
        f"{legacy['quietHourViolations']} of {len(legacy['deliveries'])}. The package sends {d['volume']:.1f}× as many "
        f"reminders per day.",
        README_END,
    ])


def update_readme(path, r):
    p = pathlib.Path(path)
    text = p.read_text(encoding="utf-8")
    if README_START not in text or README_END not in text:
        sys.exit(f"{path} has no {README_START} ... {README_END} block")
    head, rest = text.split(README_START, 1)
    tail = rest.split(README_END, 1)[1]
    p.write_text(head + readme_block(r) + tail, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--results", default=str(ROOT / "site" / "results.json"))
    parser.add_argument("--run", default=str(ROOT / "site" / "run.json"))
    parser.add_argument("--out", default=str(ROOT / "site" / "index.html"))
    parser.add_argument("--readme", help="rewrite the results block between the README markers")
    args = parser.parse_args()
    results = load(args.results)
    rel = pathlib.Path(args.results).resolve().relative_to(ROOT) if pathlib.Path(args.results).resolve().is_relative_to(ROOT) else None
    sha = git_last_commit(str(rel)) if rel else None
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(build_page(results, load(args.run), sha), encoding="utf-8")
    if args.readme:
        update_readme(args.readme, results)


if __name__ == "__main__":
    main()
